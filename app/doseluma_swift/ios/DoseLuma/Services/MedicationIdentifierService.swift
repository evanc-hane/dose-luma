import Foundation

// MARK: - Medication match result

/// A single candidate drug match returned by any identifier backend.
struct MedicationMatch: Identifiable, Sendable {
    let id:           UUID
    let drugName:     String          // e.g. "Metoprolol Tartrate"
    let genericName:  String?         // e.g. "metoprolol"
    let strength:     String?         // e.g. "25 mg"
    let ndc:          String?         // FDA NDC (US)
    let din:          String?         // Health Canada DIN (CA)
    let manufacturer: String?
    let confidence:   Double          // 0.0 – 1.0
    let matchSource:  MatchSource

    enum MatchSource: String, Sendable {
        case imprintDatabase = "Imprint DB"
        case barcodeNDC      = "Barcode / NDC"
        case visualML        = "Visual ML"
        case userConfirmed   = "User Confirmed"
    }

    init(drugName: String, genericName: String? = nil, strength: String? = nil,
         ndc: String? = nil, din: String? = nil, manufacturer: String? = nil,
         confidence: Double, matchSource: MatchSource) {
        self.id           = UUID()
        self.drugName     = drugName
        self.genericName  = genericName
        self.strength     = strength
        self.ndc          = ndc
        self.din          = din
        self.manufacturer = manufacturer
        self.confidence   = confidence
        self.matchSource  = matchSource
    }
}

// MARK: - Service protocol
//
// Conforming types receive a PillAnalysis (shape + colour + imprint + OCR text)
// and return zero or more candidate MedicationMatch values in descending
// confidence order.
//
// All conformances must be safe to call from an async context.  Heavy work
// (database queries, ML inference) should be done on background tasks.

protocol MedicationIdentifierService: Sendable {
    func identify(analysis: PillAnalysis) async -> [MedicationMatch]
}

// MARK: - Composite identifier
//
// Runs multiple backends concurrently and merges results, deduplicating by
// NDC/DIN and keeping the highest-confidence entry per drug name.

actor CompositeMedicationIdentifier: MedicationIdentifierService {
    private let backends: [any MedicationIdentifierService]

    init(backends: [any MedicationIdentifierService]) {
        self.backends = backends
    }

    init() {
        self.backends = Self.defaultBackends()
    }

    static func defaultBackends() -> [any MedicationIdentifierService] {
        [
            BarcodeNDCIdentifier(),    // Phase 1 — partial: reads barcodes already
            ImprintDatabaseIdentifier(), // Phase 2 — stub: needs bundled SQLite DB
            VisualMLIdentifier(),        // Phase 3 — stub: needs bundled .mlmodel
        ]
    }

    func identify(analysis: PillAnalysis) async -> [MedicationMatch] {
        var all: [MedicationMatch] = []
        await withTaskGroup(of: [MedicationMatch].self) { group in
            for backend in backends {
                group.addTask { await backend.identify(analysis: analysis) }
            }
            for await results in group { all.append(contentsOf: results) }
        }
        return deduplicated(all)
    }

    private func deduplicated(_ matches: [MedicationMatch]) -> [MedicationMatch] {
        var seen  = Set<String>()
        var out   = [MedicationMatch]()
        for m in matches.sorted(by: { $0.confidence > $1.confidence }) {
            let key = m.ndc ?? m.din ?? m.drugName.lowercased()
            if seen.insert(key).inserted { out.append(m) }
        }
        return out
    }
}

// MARK: - Backend 1: Barcode / NDC extractor  (ENHANCED)
//
// Scans PillAnalysis.fullText for NDC and DIN patterns with improved extraction.
// If the bundled DrugDatabase is available, resolves codes to full drug records.

struct BarcodeNDCIdentifier: MedicationIdentifierService {
    init() {}
    func identify(analysis: PillAnalysis) async -> [MedicationMatch] {
        let text = analysis.fullText
        var matches = [MedicationMatch]()

        // Enhanced NDC extraction - multiple formats
        let ndcPatterns = [
            #"\b(\d{5}-\d{4}-\d{2})\b"#,     // 5-4-2 format
            #"\b(\d{5}-\d{3}-\d{2})\b"#,     // 5-3-2 format
            #"\b(\d{4}-\d{4}-\d{2})\b"#,     // 4-4-2 format
            #"\b(\d{10,11})\b"#               // Plain digits
        ]
        
        for pattern in ndcPatterns {
            if let ndcRange = text.range(of: pattern, options: .regularExpression) {
                let ndc = String(text[ndcRange])
                if let record = DrugDatabase.shared.drug(forNDC: ndc) {
                    matches.append(record.toMatch(confidence: 0.92, source: .barcodeNDC))
                } else {
                    matches.append(MedicationMatch(
                        drugName:    "NDC \(ndc)",
                        ndc:         ndc,
                        confidence:  0.75,
                        matchSource: .barcodeNDC
                    ))
                }
                break // Found one, stop searching
            }
        }

        // DIN extraction - 8 consecutive digits or with prefix
        if let dinRange = text.range(of: #"(?:DIN[:\s]*)?(\d{8})\b"#, options: .regularExpression) {
            var din = String(text[dinRange])
            // Extract just the digits if DIN prefix present
            if let digitRange = din.range(of: #"\d{8}"#, options: .regularExpression) {
                din = String(din[digitRange])
            }
            
            if let record = DrugDatabase.shared.drug(forDIN: din) {
                matches.append(record.toMatch(confidence: 0.92, source: .barcodeNDC))
            } else {
                matches.append(MedicationMatch(
                    drugName:    "DIN \(din)",
                    din:         din,
                    confidence:  0.70,
                    matchSource: .barcodeNDC
                ))
            }
        }

        return matches
    }
}

// MARK: - Backend 2: Imprint database lookup  (STUB — Phase 2)
//
// CURRENT STATE: Returns empty; the lookup database is not yet bundled.
//
// IMPLEMENTATION PLAN:
//   1. Download the NIH NLM Pillbox dataset (public domain, discontinued
//      but data available) or the FDA Orange Book imprint table.
//   2. Convert to a SQLite database bundled as a resource in the app.
//      Schema: imprint TEXT, shape TEXT, color TEXT, ndc TEXT, name TEXT
//   3. Query: SELECT * FROM pills WHERE imprint = ? AND shape = ? AND color = ?
//      Fuzzy match via LIKE or Levenshtein distance for partial imprints.
//   4. Return top-N rows as MedicationMatch with confidence proportional
//      to how many fields matched.
//
// ESTIMATED BUNDLE SIZE: ~15–40 MB (compressed SQLite).
// PRIVACY: 100% on-device; no network call required.

struct ImprintDatabaseIdentifier: MedicationIdentifierService {
    init() {}
    func identify(analysis: PillAnalysis) async -> [MedicationMatch] {
        guard DrugDatabase.shared.isAvailable,
              let imprint = analysis.imprint, !imprint.isEmpty else { return [] }

        let records = DrugDatabase.shared.drugs(
            forImprint: imprint,
            shape:  analysis.shape == .unknown ? nil : analysis.shape.rawValue,
            color:  analysis.dominantColor == "Unknown" ? nil : analysis.dominantColor,
            limit:  5
        )

        // Confidence scales with how many attributes matched:
        // imprint-only = 0.65, + shape = 0.78, + color = 0.88
        let hasShape = analysis.shape != .unknown
        let hasColor = analysis.dominantColor != "Unknown"
        let base: Double = hasShape && hasColor ? 0.88 : hasShape || hasColor ? 0.78 : 0.65

        return records.enumerated().map { idx, record in
            // Decay confidence slightly for lower-ranked results
            record.toMatch(confidence: base - Double(idx) * 0.04,
                           source: .imprintDatabase)
        }
    }
}

// MARK: - Backend 3: Visual ML model  (STUB — Phase 3)
//
// CURRENT STATE: Returns empty; no pill-specific Core ML model is bundled.
//
// IMPLEMENTATION PLAN:
//   Option A — Fine-tuned MobileNetV3 / EfficientNet-Lite on the NIH
//     Pill Image Recognition Challenge dataset (public, CC0).
//     Train with CreateML or PyTorch → convert with coremltools.
//     Bundle as a .mlmodel (≈ 8–20 MB).
//
//   Option B — Use the existing VNClassifyImageRequest results already
//     in analysis.topClassifications but add a post-processing step
//     that maps generic class names (e.g. "capsule", "tablet") to a
//     curated candidate list, filtered by shape + colour.
//
//   Option C — Apple's upcoming VNAnalyzeImageRequest (if available in
//     future OS versions) may provide richer semantic descriptions.
//
// PRIVACY: Must remain 100% on-device; no cloud inference.

struct VisualMLIdentifier: MedicationIdentifierService {
    init() {}
    func identify(analysis: PillAnalysis) async -> [MedicationMatch] {
        // TODO (Phase 3): load bundled .mlmodel and run VNCoreMLRequest
        // let model = try? VNCoreMLModel(for: PillClassifier().model)
        // ...
        return []
    }
}
