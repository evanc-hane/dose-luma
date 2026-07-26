import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation

// MARK: - Result types

struct PillAnalysis: Equatable {

    enum Shape: String, Sendable {
        case round    = "Round"
        case oval     = "Oval"
        case oblong   = "Oblong"
        case capsule  = "Capsule"
        case unknown  = "Unknown"

        var icon: String {
            switch self {
            case .round:   return "circle.fill"
            case .oval:    return "oval.fill"
            case .oblong:  return "rectangle.fill"
            case .capsule: return "capsule.fill"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    let shape:              Shape
    let dominantColor:      String
    let secondaryColor:     String?
    let imprint:            String?        // OCR'd text on pill surface
    let topClassifications: [String]       // VNClassifyImageRequest top hits
    let fullText:           String         // raw OCR dump (for caller to reuse)

    /// Human-readable summary line, e.g. "Round · White · Imprint: L484"
    var summary: String {
        var parts = [shape.rawValue, dominantColor]
        if let imp = imprint, !imp.isEmpty { parts.append("Imprint: \(imp)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Analysis engine

/// All Vision work is done inside async continuations on Vision's own queues.
/// Calling `analyze` is safe from any async context.
actor PillAnalysisEngine {

    static let shared = PillAnalysisEngine()

    // MARK: Public entry point

    func analyze(pixelBuffer: CVPixelBuffer) async -> PillAnalysis {
        async let shapeResult  = detectShape(pixelBuffer)
        async let colorResult  = extractColors(pixelBuffer)
        async let classifResult = classifyImage(pixelBuffer)
        async let imprintResult = extractImprint(pixelBuffer)

        let (shape, colors, classifs, (imprint, fullText)) =
            await (shapeResult, colorResult, classifResult, imprintResult)

        return PillAnalysis(
            shape:              shape,
            dominantColor:      colors.dominant,
            secondaryColor:     colors.secondary,
            imprint:            imprint.isEmpty ? nil : imprint,
            topClassifications: classifs,
            fullText:           fullText
        )
    }

    // MARK: Shape detection
    //
    // VNDetectRectanglesRequest finds quadrilaterals; aspect ratio maps to shape.

    private func detectShape(_ pixelBuffer: CVPixelBuffer) async -> PillAnalysis.Shape {
        await withCheckedContinuation { cont in
            let req = VNDetectRectanglesRequest { req, _ in
                guard let results = req.results as? [VNRectangleObservation],
                      let best = results.first else {
                    cont.resume(returning: .unknown)
                    return
                }

                let w  = best.boundingBox.width
                let h  = best.boundingBox.height
                guard w > 0, h > 0 else { cont.resume(returning: .unknown); return }

                let aspect = max(w, h) / min(w, h)

                let shape: PillAnalysis.Shape
                switch aspect {
                case ..<1.25:  shape = .round
                case ..<1.7:   shape = .oval
                case ..<2.5:   shape = .oblong
                default:       shape = .capsule
                }
                cont.resume(returning: shape)
            }
            req.minimumAspectRatio   = 0.1
            req.maximumAspectRatio   = 1.0
            req.minimumSize          = 0.04
            req.maximumObservations  = 5
            req.quadratureTolerance  = 30

            try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                       orientation: .right, options: [:])
                .perform([req])
        }
    }

    // MARK: Color extraction
    //
    // Uses CIAreaAverage on the central 50 % of the frame to get the dominant
    // pill colour, then samples a second region offset from centre for a
    // potential secondary colour (e.g. two-tone capsules).

    private struct ColorPair { let dominant: String; let secondary: String? }

    private func extractColors(_ pixelBuffer: CVPixelBuffer) async -> ColorPair {
        let ciImage  = CIImage(cvPixelBuffer: pixelBuffer)
        let context  = CIContext(options: [.useSoftwareRenderer: false])
        let ext      = ciImage.extent

        func avgColor(rect: CGRect) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
            let filter = CIFilter.areaAverage()
            filter.inputImage = ciImage.cropped(to: rect)
            filter.extent     = rect
            guard let out = filter.outputImage,
                  let cg  = context.createCGImage(out, from: CGRect(x: 0, y: 0, width: 1, height: 1)),
                  let dp  = cg.dataProvider?.data else { return nil }
            let ptr = CFDataGetBytePtr(dp)
            guard let ptr else { return nil }
            return (CGFloat(ptr[0]) / 255, CGFloat(ptr[1]) / 255, CGFloat(ptr[2]) / 255)
        }

        let centreRect = CGRect(x: ext.width * 0.25, y: ext.height * 0.25,
                                width: ext.width * 0.5, height: ext.height * 0.5)
        let leftRect   = CGRect(x: ext.width * 0.15, y: ext.height * 0.4,
                                width: ext.width * 0.2, height: ext.height * 0.2)
        let rightRect  = CGRect(x: ext.width * 0.65, y: ext.height * 0.4,
                                width: ext.width * 0.2, height: ext.height * 0.2)

        let dominant  = avgColor(rect: centreRect).map { colorName($0.r, $0.g, $0.b) } ?? "Unknown"
        let leftCol   = avgColor(rect: leftRect).map  { colorName($0.r, $0.g, $0.b) }
        let rightCol  = avgColor(rect: rightRect).map { colorName($0.r, $0.g, $0.b) }

        var secondary: String? = nil
        if let l = leftCol, let r = rightCol, l != r, l != dominant { secondary = "\(l) / \(r)" }

        return ColorPair(dominant: dominant, secondary: secondary)
    }

    // Maps RGB → human-readable colour name via HSV.
    private func colorName(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> String {
        let mx = max(r, g, b)
        let mn = min(r, g, b)
        let delta = mx - mn
        let sat = mx == 0 ? CGFloat(0) : delta / mx
        let bri = mx

        if sat < 0.12 {
            if bri > 0.88 { return "White" }
            if bri > 0.60 { return "Light Gray" }
            if bri > 0.35 { return "Gray" }
            return "Black"
        }
        if sat < 0.25 && bri > 0.78 { return "Off-White" }

        var hue: CGFloat = 0
        if delta > 0 {
            if mx == r      { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if mx == g { hue = (b - r) / delta + 2 }
            else            { hue = (r - g) / delta + 4 }
            hue = hue * 60
            if hue < 0 { hue += 360 }
        }

        switch hue {
        case 0..<18:    return bri > 0.45 ? "Red"    : "Dark Red"
        case 18..<45:   return sat > 0.55 ? "Orange" : "Brown"
        case 45..<75:   return "Yellow"
        case 75..<155:  return bri > 0.45 ? "Green"  : "Dark Green"
        case 155..<195: return "Teal"
        case 195..<265: return bri > 0.45 ? "Blue"   : "Dark Blue"
        case 265..<295: return "Purple"
        case 295..<335: return "Pink"
        default:        return "Red"
        }
    }

    // MARK: Image classification
    //
    // VNClassifyImageRequest uses Apple's on-device neural net (~1000 classes).
    // We keep the top 5 and flag medication-related ones.

    private static let medKeywords = ["pill","tablet","capsule","pharmaceutical",
                                      "medicine","drug","medication","blister"]

    private func classifyImage(_ pixelBuffer: CVPixelBuffer) async -> [String] {
        await withCheckedContinuation { cont in
            let req = VNClassifyImageRequest { req, _ in
                guard let obs = req.results as? [VNClassificationObservation] else {
                    cont.resume(returning: [])
                    return
                }
                let filtered = obs.filter { $0.confidence > 0.04 }

                // Prefer medication-related hits; fall back to top general hits
                var med = filtered.filter { o in
                    PillAnalysisEngine.medKeywords.contains { o.identifier.lowercased().contains($0) }
                }
                if med.isEmpty { med = Array(filtered.prefix(5)) }

                let labels = med.prefix(5).map {
                    "\($0.identifier.replacingOccurrences(of: "_", with: " ").capitalized) (\(Int($0.confidence * 100))%)"
                }
                cont.resume(returning: Array(labels))
            }

            try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                       orientation: .right, options: [:])
                .perform([req])
        }
    }

    // MARK: Imprint OCR
    //
    // Reads text printed/embossed on the pill surface.
    // `usesLanguageCorrection = false` preserves drug imprints verbatim.

    private func extractImprint(_ pixelBuffer: CVPixelBuffer) async -> (String, String) {
        await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { req, _ in
                guard let obs = req.results as? [VNRecognizedTextObservation] else {
                    cont.resume(returning: ("", ""))
                    return
                }
                let lines = obs
                    .filter  { $0.confidence >= 0.3 }
                    .compactMap { $0.topCandidates(1).first?.string }

                var seen = Set<String>()
                let deduped = lines.filter { seen.insert($0).inserted }

                // Imprint = short tokens (≤ 8 chars) that look like drug codes
                let imprint = deduped
                    .filter { $0.count <= 8 }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let full = deduped.joined(separator: "\n")
                cont.resume(returning: (imprint, full))
            }
            req.recognitionLevel       = .accurate
            req.usesLanguageCorrection = false
            req.minimumTextHeight      = 0.01

            try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                       orientation: .right, options: [:])
                .perform([req])
        }
    }
}
