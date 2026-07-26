import SwiftUI
import AVFoundation
import Vision

// MARK: - SwiftUI bridge

struct PillScannerView: UIViewControllerRepresentable {
    @Binding var result: PillAnalysis?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PillCameraViewController {
        let vc = PillCameraViewController()
        vc.onResult = { analysis in
            result = analysis
            dismiss()
        }
        vc.onCancel = { dismiss() }
        return vc
    }

    func updateUIViewController(_ uiViewController: PillCameraViewController, context: Context) {}
}

// MARK: - Camera + analysis view controller

final class PillCameraViewController: UIViewController {
    var onResult: ((PillAnalysis) -> Void)?
    var onCancel: (() -> Void)?

    private let session       = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let pillDelegate  = PillFrameDelegate()
    private let sessionQueue  = DispatchQueue(label: "doseluma.pill.session")

    // Live bounding-box overlay for detected shapes
    private let shapeOverlayLayer = CALayer()

    // Frozen frame waiting for full analysis
    private var frozenBuffer: CVPixelBuffer?

    // Result card overlay (shown after analysis)
    private var resultCard: UIView?

    // State
    private enum State { case scanning, analyzing, showingResult(PillAnalysis) }
    private var scanState: State = .scanning

    private var torchOn = false

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupOverlayLayers()
        setupControls()

        pillDelegate.onShapeRects = { [weak self] rects in
            self?.updateShapeOverlay(rects)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame  = view.bounds
        shapeOverlayLayer.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { self.session.stopRunning() }
    }

    // MARK: Camera

    private func setupCamera() {
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input  = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(pillDelegate, queue: DispatchQueue(label: "doseluma.pill.ocr"))
        if session.canAddOutput(output) { session.addOutput(output) }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        sessionQueue.async { self.session.startRunning() }
    }

    // MARK: Overlay layers

    private func setupOverlayLayers() {
        shapeOverlayLayer.backgroundColor = UIColor.clear.cgColor
        view.layer.addSublayer(shapeOverlayLayer)
    }

    /// Redraws bounding-box outlines around detected pill shapes (live).
    private func updateShapeOverlay(_ normalizedRects: [CGRect]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.shapeOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

            for normRect in normalizedRects {
                // Flip and scale from normalised Vision coordinates to view coordinates
                let vb    = self.view.bounds
                let vRect = CGRect(
                    x:      normRect.minX * vb.width,
                    y:      (1 - normRect.maxY) * vb.height,
                    width:  normRect.width  * vb.width,
                    height: normRect.height * vb.height
                )

                let box = CALayer()
                box.frame            = vRect
                box.borderColor      = UIColor.systemYellow.withAlphaComponent(0.85).cgColor
                box.borderWidth      = 2.5
                box.cornerRadius     = 6
                box.backgroundColor  = UIColor.systemYellow.withAlphaComponent(0.08).cgColor
                self.shapeOverlayLayer.addSublayer(box)
            }
        }
    }

    // MARK: Controls

    private func setupControls() {
        // Cancel
        let cancelBtn = pillButton("Cancel", style: .ghost)
        cancelBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        // Torch
        let torchBtn = iconButton(systemName: "bolt.fill")
        torchBtn.addTarget(self, action: #selector(torchTapped), for: .touchUpInside)

        // Analyse (primary action)
        let analyseBtn = pillButton("Analyze Pill", style: .primary)
        analyseBtn.tag = 100
        analyseBtn.addTarget(self, action: #selector(analyzeTapped), for: .touchUpInside)

        // Instruction
        let label = UILabel()
        label.text          = "Hold camera over a pill or capsule"
        label.textColor     = .white
        label.font          = .systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        label.layer.cornerRadius = 8
        label.clipsToBounds      = true
        label.translatesAutoresizingMaskIntoConstraints = false

        [cancelBtn, torchBtn, analyseBtn, label].forEach { view.addSubview($0) }

        NSLayoutConstraint.activate([
            cancelBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancelBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            torchBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            torchBtn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            torchBtn.widthAnchor.constraint(equalToConstant: 40),
            torchBtn.heightAnchor.constraint(equalToConstant: 40),

            label.bottomAnchor.constraint(equalTo: analyseBtn.topAnchor, constant: -12),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            analyseBtn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            analyseBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            analyseBtn.widthAnchor.constraint(equalToConstant: 160),
            analyseBtn.heightAnchor.constraint(equalToConstant: 54),
        ])
    }

    // MARK: Actions

    @objc private func cancelTapped() { onCancel?() }

    @objc private func torchTapped() {
        guard let d = AVCaptureDevice.default(for: .video), d.hasTorch else { return }
        torchOn.toggle()
        try? d.lockForConfiguration()
        d.torchMode = torchOn ? .on : .off
        d.unlockForConfiguration()
    }

    @objc private func analyzeTapped() {
        guard let px = pillDelegate.latestBuffer else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        // Stop live detection during analysis
        pillDelegate.isPaused = true
        shapeOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        // Show spinner
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()

        if let btn = view.viewWithTag(100) as? UIButton { btn.isEnabled = false }

        Task {
            let analysis = await PillAnalysisEngine.shared.analyze(pixelBuffer: px)
            let matches  = await CompositeMedicationIdentifier().identify(analysis: analysis)
            SyncService.shared.logPillScan(analysis: analysis, matches: matches)
            await MainActor.run {
                spinner.removeFromSuperview()
                self.showResultCard(analysis, matches: matches)
            }
        }
    }

    // MARK: Result card

    private func showResultCard(_ analysis: PillAnalysis, matches: [MedicationMatch] = []) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        let card = UIView()
        card.backgroundColor      = UIColor.systemBackground.withAlphaComponent(0.95)
        card.layer.cornerRadius   = 20
        card.layer.shadowOpacity  = 0.25
        card.layer.shadowRadius   = 12
        card.layer.shadowOffset   = CGSize(width: 0, height: 4)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        // Shape icon + label
        let shapeImg = UIImageView(image: UIImage(systemName: analysis.shape.icon))
        shapeImg.tintColor = .systemYellow
        shapeImg.contentMode = .scaleAspectFit
        shapeImg.translatesAutoresizingMaskIntoConstraints = false

        let shapeLbl = cardLabel(analysis.shape.rawValue, style: .body)

        // Color swatch
        let swatchRow = colorSwatchRow(dominant: analysis.dominantColor,
                                       secondary: analysis.secondaryColor)

        // Imprint
        let imprintRow: UIView
        if let imp = analysis.imprint, !imp.isEmpty {
            imprintRow = labeledRow(key: "Imprint", value: imp)
        } else {
            imprintRow = labeledRow(key: "Imprint", value: "None detected")
        }

        // Classifier top hit
        let classifRow: UIView
        if let top = analysis.topClassifications.first {
            classifRow = labeledRow(key: "Classifier", value: top)
        } else {
            classifRow = UIView()
        }

        // Possible medication matches
        let matchesRow = matchesSection(matches)

        // Buttons
        let useBtn    = pillButton("Use This", style: .primary)
        useBtn.addTarget(self, action: #selector(useResultTapped), for: .touchUpInside)
        useBtn.accessibilityLabel = "confirm"

        let rescanBtn = pillButton("Re-scan", style: .ghost)
        rescanBtn.addTarget(self, action: #selector(rescanTapped), for: .touchUpInside)

        let btnRow = UIStackView(arrangedSubviews: [rescanBtn, useBtn])
        btnRow.axis    = .horizontal
        btnRow.spacing = 12
        btnRow.distribution = .fillEqually
        btnRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            hstack(shapeImg, shapeLbl),
            swatchRow, imprintRow, classifRow, matchesRow, btnRow
        ])
        stack.axis    = NSLayoutConstraint.Axis.vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),

            shapeImg.widthAnchor.constraint(equalToConstant: 28),
            shapeImg.heightAnchor.constraint(equalToConstant: 28),
            btnRow.heightAnchor.constraint(equalToConstant: 48),
        ])

        // Store for removal on re-scan
        resultCard?.removeFromSuperview()
        resultCard = card
        objc_setAssociatedObject(card, &PillCameraViewController.analysisKey, analysis, .OBJC_ASSOCIATION_RETAIN)

        // Animate up
        card.transform = CGAffineTransform(translationX: 0, y: 60)
        card.alpha = 0
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0.3) {
            card.transform = .identity
            card.alpha = 1
        }
    }

    private static var analysisKey: UInt8 = 0

    @objc private func useResultTapped() {
        guard let card = resultCard,
              let analysis = objc_getAssociatedObject(card, &PillCameraViewController.analysisKey) as? PillAnalysis else { return }
        onResult?(analysis)
    }

    @objc private func rescanTapped() {
        resultCard?.removeFromSuperview()
        resultCard = nil
        pillDelegate.isPaused = false
        if let btn = view.viewWithTag(100) as? UIButton { btn.isEnabled = true }
    }

    // MARK: UIKit helpers

    enum ButtonStyle { case primary, ghost }

    private func pillButton(_ title: String, style: ButtonStyle) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.layer.cornerRadius = 14
        btn.translatesAutoresizingMaskIntoConstraints = false
        switch style {
        case .primary:
            btn.backgroundColor = .white
            btn.setTitleColor(.black, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        case .ghost:
            btn.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            btn.setTitleColor(.white, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        }
        return btn
    }

    private func iconButton(systemName: String) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: systemName), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        btn.layer.cornerRadius = 20
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    private func cardLabel(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let lbl = UILabel()
        lbl.text = text
        lbl.font = .preferredFont(forTextStyle: style)
        lbl.textColor = .label
        lbl.translatesAutoresizingMaskIntoConstraints = false
        return lbl
    }

    /// Builds the "Possible Matches" section of the result card.
    /// Shows real matches when available, otherwise shows a placeholder that
    /// communicates the feature is coming (Phase 2 / Phase 3).
    private func matchesSection(_ matches: [MedicationMatch]) -> UIView {
        let header = UILabel()
        header.text      = "Possible Medications"
        header.font      = .systemFont(ofSize: 13, weight: .regular)
        header.textColor = .secondaryLabel

        let container = UIStackView(arrangedSubviews: [header])
        container.axis    = NSLayoutConstraint.Axis.vertical
        container.spacing = 6

        if matches.isEmpty {
            // Placeholder — shown until Phase 2/3 backends are implemented
            let placeholder = UIView()
            placeholder.backgroundColor  = UIColor.systemOrange.withAlphaComponent(0.08)
            placeholder.layer.cornerRadius = 8
            placeholder.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.3).cgColor
            placeholder.layer.borderWidth = 1

            let icon = UILabel()
            icon.text = "🔬"
            icon.font = .systemFont(ofSize: 18)
            icon.translatesAutoresizingMaskIntoConstraints = false

            let msg = UILabel()
            msg.text          = "Drug identification coming in Phase 2.\nWill use imprint DB + visual ML model."
            msg.font          = .systemFont(ofSize: 11, weight: .regular)
            msg.textColor     = .secondaryLabel
            msg.numberOfLines = 0
            msg.translatesAutoresizingMaskIntoConstraints = false

            let row = UIStackView(arrangedSubviews: [icon, msg])
            row.axis      = .horizontal
            row.spacing   = 8
            row.alignment = .center
            row.translatesAutoresizingMaskIntoConstraints = false

            placeholder.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: placeholder.leadingAnchor, constant: 10),
                row.trailingAnchor.constraint(equalTo: placeholder.trailingAnchor, constant: -10),
                row.topAnchor.constraint(equalTo: placeholder.topAnchor, constant: 8),
                row.bottomAnchor.constraint(equalTo: placeholder.bottomAnchor, constant: -8),
            ])
            container.addArrangedSubview(placeholder)
        } else {
            for match in matches.prefix(3) {
                let matchView = UIView()
                matchView.backgroundColor   = UIColor.systemGreen.withAlphaComponent(0.08)
                matchView.layer.cornerRadius = 8

                let nameLbl = UILabel()
                nameLbl.text      = match.drugName
                nameLbl.font      = .systemFont(ofSize: 13, weight: .semibold)
                nameLbl.textColor = .label

                var detailParts = [String]()
                if let s = match.strength    { detailParts.append(s) }
                if let n = match.ndc         { detailParts.append("NDC \(n)") }
                if let d = match.din         { detailParts.append("DIN \(d)") }
                detailParts.append("\(match.matchSource.rawValue) · \(Int(match.confidence * 100))%")

                let detailLbl = UILabel()
                detailLbl.text          = detailParts.joined(separator: " · ")
                detailLbl.font          = .systemFont(ofSize: 11)
                detailLbl.textColor     = .secondaryLabel
                detailLbl.numberOfLines = 0

                let inner = UIStackView(arrangedSubviews: [nameLbl, detailLbl])
                inner.axis    = NSLayoutConstraint.Axis.vertical
                inner.spacing = 2
                inner.translatesAutoresizingMaskIntoConstraints = false
                matchView.addSubview(inner)
                NSLayoutConstraint.activate([
                    inner.leadingAnchor.constraint(equalTo: matchView.leadingAnchor, constant: 10),
                    inner.trailingAnchor.constraint(equalTo: matchView.trailingAnchor, constant: -10),
                    inner.topAnchor.constraint(equalTo: matchView.topAnchor, constant: 8),
                    inner.bottomAnchor.constraint(equalTo: matchView.bottomAnchor, constant: -8),
                ])
                container.addArrangedSubview(matchView)
            }
        }
        return container
    }

    private func labeledRow(key: String, value: String) -> UIView {
        let kLbl = UILabel()
        kLbl.text      = key
        kLbl.font      = .systemFont(ofSize: 13, weight: .regular)
        kLbl.textColor = .secondaryLabel

        let vLbl = UILabel()
        vLbl.text      = value
        vLbl.font      = .systemFont(ofSize: 14, weight: .semibold)
        vLbl.textColor = .label
        vLbl.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [kLbl, vLbl])
        stack.axis    = .vertical
        stack.spacing = 2
        return stack
    }

    private func colorSwatchRow(dominant: String, secondary: String?) -> UIView {
        let dot = UIView()
        dot.backgroundColor   = uiColor(from: dominant)
        dot.layer.cornerRadius = 10
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 20),
            dot.heightAnchor.constraint(equalToConstant: 20),
        ])

        let label = UILabel()
        label.text      = secondary != nil ? "\(dominant) / \(secondary!)" : dominant
        label.font      = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .label

        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis    = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    private func hstack(_ a: UIView, _ b: UIView) -> UIStackView {
        let s = UIStackView(arrangedSubviews: [a, b])
        s.axis = .horizontal; s.spacing = 10; s.alignment = .center
        return s
    }

    // Approximate UIColor from color name string
    private func uiColor(from name: String) -> UIColor {
        switch name.lowercased() {
        case "white", "off-white": return .white
        case "black":              return .black
        case "red", "dark red":    return .systemRed
        case "orange":             return .systemOrange
        case "yellow":             return .systemYellow
        case "green", "dark green":return .systemGreen
        case "blue", "dark blue":  return .systemBlue
        case "purple":             return .systemPurple
        case "pink":               return .systemPink
        case "teal":               return .systemTeal
        case "brown":              return .brown
        default:                   return .systemGray
        }
    }
}

// MARK: - Live shape detection delegate

/// Runs on a background queue. Throttled to 3 fps for live shape overlays.
/// Exposes `latestBuffer` so the VC can grab a frame for full analysis.
final class PillFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onShapeRects: (([CGRect]) -> Void)?
    var isPaused     = false
    private(set) var latestBuffer: CVPixelBuffer?

    private var lastShapeRun: Date = .distantPast
    private let shapeThrottle: TimeInterval = 0.33

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestBuffer = px
        guard !isPaused else { return }

        let now = Date()
        guard now.timeIntervalSince(lastShapeRun) >= shapeThrottle else { return }
        lastShapeRun = now

        let req = VNDetectRectanglesRequest { [weak self] req, _ in
            let rects = (req.results as? [VNRectangleObservation])?.map { $0.boundingBox } ?? []
            self?.onShapeRects?(rects)
        }
        req.minimumAspectRatio  = 0.1
        req.maximumAspectRatio  = 1.0
        req.minimumSize         = 0.04
        req.maximumObservations = 5

        try? VNImageRequestHandler(cvPixelBuffer: px, orientation: .right, options: [:])
            .perform([req])
    }
}
