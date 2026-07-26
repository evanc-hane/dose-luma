import SwiftUI
import SwiftUI
import AVFoundation
import Vision
import VisionKit
import PhotosUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Public SwiftUI entry point
//
// Shows a choice menu: Camera or Photo Library.
// Camera uses DataScannerViewController (VisionKit, iOS 16+) or Vision + AVCapture fallback.
// Photo Library uses PhotosPicker for selecting images to run OCR on.

struct OCRScannerView: View {
    @Binding var detectedText: String?
    @Environment(\.dismiss) private var dismiss
    
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isProcessingPhoto = false
    @State private var showMultiShotMode = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 72))
                    .foregroundStyle(.blue.gradient)
                    .padding(.top, 60)
                
                Text("Scan Medication Label")
                    .font(.title2.bold())
                
                Text("Choose how you'd like to scan the label")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Spacer()
                
                VStack(spacing: 16) {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Multi-Shot Camera", systemImage: "camera.on.rectangle")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.blue.gradient)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Choose Multiple Photos", systemImage: "photo.stack")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 32)
                
                Text("💡 Tip: Take multiple photos to capture all sides of the bottle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 40)
            }
            .navigationTitle("OCR Scanner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                MultiShotCameraView(detectedText: $detectedText)
                    .onDisappear {
                        if detectedText != nil {
                            dismiss()
                        }
                    }
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $selectedPhotos,
                maxSelectionCount: 5,
                matching: .images
            )
            .onChange(of: selectedPhotos) { newValue in
                guard !newValue.isEmpty else { return }
                processMultiplePhotos(newValue)
            }
            .overlay {
                if isProcessingPhoto {
                    ZStack {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                        
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.white)
                            Text("Processing images...")
                                .foregroundStyle(.white)
                                .font(.subheadline)
                        }
                        .padding(32)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
    }
    
    private func processMultiplePhotos(_ items: [PhotosPickerItem]) {
        isProcessingPhoto = true
        
        Task {
            defer { 
                isProcessingPhoto = false
                selectedPhotos.removeAll()
            }
            
            var allText: [String] = []
            
            // Process each photo
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let uiImage = UIImage(data: data),
                      let cgImage = uiImage.cgImage else {
                    continue
                }
                
                let text = await performOCR(on: cgImage)
                if !text.isEmpty {
                    allText.append(text)
                }
            }
            
            // Merge and deduplicate text from all images
            let mergedText = mergeOCRResults(allText)
            
            if !mergedText.isEmpty {
                await MainActor.run {
                    detectedText = mergedText
                    dismiss()
                }
            }
        }
    }
    
    /// Merge OCR results from multiple images, removing duplicates while preserving important information
    private func mergeOCRResults(_ results: [String]) -> String {
        guard !results.isEmpty else { return "" }

        // Collect all unique lines across all images
        var allLines = Set<String>()
        var orderedLines: [String] = []

        for result in results {
            let lines = result.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            for line in lines {
                // Skip Rx/prescription numbers (lines starting with # or Rx followed by numbers)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") || trimmed.hasPrefix("Rx") || trimmed.hasPrefix("RX") {
                    continue
                }

                // Use normalized version for duplicate detection
                let normalized = line.lowercased()
                if allLines.insert(normalized).inserted {
                    orderedLines.append(line)
                }
            }
        }
        
        // Smart grouping: Try to identify and group related information
        var grouped: [String: [String]] = [
            "drugInfo": [],
            "codes": [],
            "instructions": [],
            "warnings": [],
            "other": []
        ]
        
        for line in orderedLines {
            let upper = line.uppercased()
            
            if upper.contains("NDC") || upper.contains("DIN") || upper.contains("LOT") || upper.contains("EXP") {
                grouped["codes"]?.append(line)
            } else if upper.contains("DIRECTION") || upper.contains("TAKE") || upper.contains("USE") || upper.contains("DOSAGE") {
                grouped["instructions"]?.append(line)
            } else if upper.contains("WARNING") || upper.contains("CAUTION") || upper.contains("DO NOT") {
                grouped["warnings"]?.append(line)
            } else if line.contains("mg") || line.contains("mcg") || line.contains("mL") {
                grouped["drugInfo"]?.append(line)
            } else {
                grouped["other"]?.append(line)
            }
        }
        
        // Reconstruct in logical order
        var final: [String] = []
        
        // Drug info first (name, strength, form)
        if let drugInfo = grouped["drugInfo"], !drugInfo.isEmpty {
            final.append(contentsOf: drugInfo)
        }
        
        // Identification codes
        if let codes = grouped["codes"], !codes.isEmpty {
            final.append(contentsOf: codes)
        }
        
        // Instructions
        if let instructions = grouped["instructions"], !instructions.isEmpty {
            final.append(contentsOf: instructions)
        }
        
        // Warnings
        if let warnings = grouped["warnings"], !warnings.isEmpty {
            final.append(contentsOf: warnings)
        }
        
        // Other information
        if let other = grouped["other"], !other.isEmpty {
            final.append(contentsOf: other)
        }
        
        return final.joined(separator: "\n")
    }
    
    private func performOCR(on image: CGImage) async -> String {
        // Try enhanced preprocessing for better OCR results
        let processedImage = await enhanceImageForOCR(image)
        
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012  // Slightly lower to catch smaller text
        request.recognitionLanguages = ["en-US"]  // Optimize for English
        
        // Enable automatic language detection for better accuracy
        request.automaticallyDetectsLanguage = true
        
        let handler = VNImageRequestHandler(cgImage: processedImage, options: [:])
        
        do {
            try handler.perform([request])
            
            guard let observations = request.results else {
                return ""
            }
            
            // Group observations by vertical position to maintain label structure
            let grouped = groupTextByLines(observations)
            
            // Extract medication-specific information with higher priority
            let lines = grouped
                .filter { $0.confidence >= 0.35 }  // Slightly lower threshold
                .compactMap { $0.topCandidates(3).first?.string }  // Consider top 3 candidates
            
            // Deduplicate while preserving order
            var seen = Set<String>()
            let deduped = lines.filter { seen.insert($0).inserted }
            
            return deduped.joined(separator: "\n")
        } catch {
            print("OCR Error: \(error)")
            return ""
        }
    }
    
    /// Enhance image for better OCR accuracy using Core Image filters
    private func enhanceImageForOCR(_ image: CGImage) async -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        
        // Apply exposure adjustment for better contrast
        let exposureFilter = CIFilter.exposureAdjust()
        exposureFilter.inputImage = ciImage
        exposureFilter.ev = 0.5
        
        // Apply sharpening to make text edges clearer
        let sharpenFilter = CIFilter.sharpenLuminance()
        sharpenFilter.inputImage = exposureFilter.outputImage
        sharpenFilter.sharpness = 0.8
        
        // Enhance contrast
        let contrastFilter = CIFilter.colorControls()
        contrastFilter.inputImage = sharpenFilter.outputImage
        contrastFilter.contrast = 1.3
        
        guard let outputImage = contrastFilter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return image  // Return original if processing fails
        }
        
        return cgImage
    }
    
    /// Group text observations by vertical position to maintain structure
    private func groupTextByLines(_ observations: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
        // Sort by Y position (top to bottom)
        return observations.sorted { lhs, rhs in
            lhs.boundingBox.midY > rhs.boundingBox.midY  // Vision coordinates are bottom-up
        }
    }
}

// MARK: - Multi-Shot Camera View
//
// Allows users to capture multiple photos of a medication bottle to get all label information.
// Each capture is processed and stored, then all results are merged when user finishes.

struct MultiShotCameraView: View {
    @Binding var detectedText: String?
    @Environment(\.dismiss) private var dismiss
    
    @State private var capturedImages: [UIImage] = []
    @State private var ocrResults: [String] = []
    @State private var isProcessing = false
    @State private var showPreview = false
    
    var body: some View {
        ZStack {
            // Camera view
            MultiShotCameraViewRepresentable(
                onCapture: { image in
                    handleCapture(image)
                },
                onCancel: {
                    if !capturedImages.isEmpty {
                        showPreview = true
                    } else {
                        dismiss()
                    }
                }
            )
            
            // Top HUD
            VStack {
                HStack {
                    Button {
                        if !capturedImages.isEmpty {
                            showPreview = true
                        } else {
                            dismiss()
                        }
                    } label: {
                        Text(capturedImages.isEmpty ? "Cancel" : "Done (\(capturedImages.count))")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.5))
                            .clipShape(Capsule())
                    }
                    
                    Spacer()
                    
                    if !capturedImages.isEmpty {
                        Text("\(capturedImages.count) photo\(capturedImages.count == 1 ? "" : "s")")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.blue)
                            .clipShape(Capsule())
                    }
                }
                .padding()
                
                Spacer()
            }
            
            // Bottom instruction
            VStack {
                Spacer()
                
                if capturedImages.isEmpty {
                    Text("Capture first side of the bottle")
                } else {
                    Text("Rotate bottle and capture another side")
                }
                
                Text("Tap 'Done' when you've captured all sides")
                    .font(.caption)
            }
            .foregroundStyle(.white)
            .padding()
            .background(.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 100)
            
            // Processing overlay
            if isProcessing {
                ZStack {
                    Color.black.opacity(0.7)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Processing image \(ocrResults.count + 1) of \(capturedImages.count)...")
                            .foregroundStyle(.white)
                    }
                    .padding(32)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .sheet(isPresented: $showPreview) {
            MultiShotPreviewView(
                images: capturedImages,
                ocrResults: ocrResults,
                onConfirm: {
                    finalizeMultiShot()
                },
                onRetake: {
                    capturedImages.removeAll()
                    ocrResults.removeAll()
                    showPreview = false
                }
            )
        }
    }
    
    private func handleCapture(_ image: UIImage) {
        capturedImages.append(image)
        
        // Process OCR in background
        Task {
            isProcessing = true
            defer { isProcessing = false }
            
            guard let cgImage = image.cgImage else { return }
            let text = await performOCR(on: cgImage)
            
            await MainActor.run {
                ocrResults.append(text)
            }
        }
    }
    
    private func finalizeMultiShot() {
        // Merge all OCR results
        let merged = mergeOCRResults(ocrResults)
        detectedText = merged
        dismiss()
    }
    
    private func performOCR(on image: CGImage) async -> String {
        // Use the same OCR logic as the main scanner
        let processedImage = await enhanceImageForOCR(image)
        
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = true
        
        let handler = VNImageRequestHandler(cgImage: processedImage, options: [:])
        
        do {
            try handler.perform([request])
            
            guard let observations = request.results else {
                return ""
            }
            
            let grouped = groupTextByLines(observations)
            let lines = grouped
                .filter { $0.confidence >= 0.35 }
                .compactMap { $0.topCandidates(3).first?.string }
            
            var seen = Set<String>()
            let deduped = lines.filter { seen.insert($0).inserted }
            
            return deduped.joined(separator: "\n")
        } catch {
            print("OCR Error: \(error)")
            return ""
        }
    }
    
    private func enhanceImageForOCR(_ image: CGImage) async -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        
        let exposureFilter = CIFilter.exposureAdjust()
        exposureFilter.inputImage = ciImage
        exposureFilter.ev = 0.5
        
        let sharpenFilter = CIFilter.sharpenLuminance()
        sharpenFilter.inputImage = exposureFilter.outputImage
        sharpenFilter.sharpness = 0.8
        
        let contrastFilter = CIFilter.colorControls()
        contrastFilter.inputImage = sharpenFilter.outputImage
        contrastFilter.contrast = 1.3
        
        guard let outputImage = contrastFilter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }
        
        return cgImage
    }
    
    private func groupTextByLines(_ observations: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
        return observations.sorted { lhs, rhs in
            lhs.boundingBox.midY > rhs.boundingBox.midY
        }
    }
    
    private func mergeOCRResults(_ results: [String]) -> String {
        guard !results.isEmpty else { return "" }

        var allLines = Set<String>()
        var orderedLines: [String] = []

        for result in results {
            let lines = result.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            for line in lines {
                // Skip Rx/prescription numbers (lines starting with # or Rx followed by numbers)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") || trimmed.hasPrefix("Rx") || trimmed.hasPrefix("RX") {
                    continue
                }

                let normalized = line.lowercased()
                if allLines.insert(normalized).inserted {
                    orderedLines.append(line)
                }
            }
        }

        var grouped: [String: [String]] = [
            "drugInfo": [],
            "codes": [],
            "instructions": [],
            "warnings": [],
            "other": []
        ]

        for line in orderedLines {
            let upper = line.uppercased()

            if upper.contains("NDC") || upper.contains("DIN") || upper.contains("LOT") || upper.contains("EXP") {
                grouped["codes"]?.append(line)
            } else if upper.contains("DIRECTION") || upper.contains("TAKE") || upper.contains("USE") || upper.contains("DOSAGE") {
                grouped["instructions"]?.append(line)
            } else if upper.contains("WARNING") || upper.contains("CAUTION") || upper.contains("DO NOT") {
                grouped["warnings"]?.append(line)
            } else if line.contains("mg") || line.contains("mcg") || line.contains("mL") || line.contains("meq") {
                grouped["drugInfo"]?.append(line)
            } else {
                grouped["other"]?.append(line)
            }
        }

        var final: [String] = []

        if let drugInfo = grouped["drugInfo"], !drugInfo.isEmpty {
            final.append(contentsOf: drugInfo)
        }
        if let codes = grouped["codes"], !codes.isEmpty {
            final.append(contentsOf: codes)
        }
        if let instructions = grouped["instructions"], !instructions.isEmpty {
            final.append(contentsOf: instructions)
        }
        if let warnings = grouped["warnings"], !warnings.isEmpty {
            final.append(contentsOf: warnings)
        }
        if let other = grouped["other"], !other.isEmpty {
            final.append(contentsOf: other)
        }

        return final.joined(separator: "\n")
    }
}

// MARK: - Multi-Shot Preview View
//
// Shows thumbnails of captured images and merged OCR results

struct MultiShotPreviewView: View {
    let images: [UIImage]
    let ocrResults: [String]
    let onConfirm: () -> Void
    let onRetake: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Image thumbnails
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                                    VStack(spacing: 8) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 120, height: 160)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                        
                                        Text("Photo \(index + 1)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    } header: {
                        HStack {
                            Label("Captured Images", systemImage: "photo.stack")
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.horizontal)
                    }
                    
                    Divider()
                        .padding(.horizontal)
                    
                    // Detected text preview
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Detected Text", systemImage: "doc.text")
                                .font(.headline)
                            
                            if ocrResults.isEmpty {
                                Text("Processing...")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding()
                            } else {
                                let merged = mergePreview(ocrResults)
                                Text(merged.isEmpty ? "No text detected" : merged)
                                    .font(.body)
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Review Captures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Retake") {
                        onRetake()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This") {
                        onConfirm()
                        dismiss()
                    }
                    .disabled(ocrResults.isEmpty)
                }
            }
        }
    }
    
    private func mergePreview(_ results: [String]) -> String {
        var allLines = Set<String>()
        var orderedLines: [String] = []
        
        for result in results {
            let lines = result.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            
            for line in lines {
                let normalized = line.lowercased()
                if allLines.insert(normalized).inserted {
                    orderedLines.append(line)
                }
            }
        }
        
        return orderedLines.joined(separator: "\n")
    }
}

// MARK: - Multi-Shot Camera UIKit Wrapper

struct MultiShotCameraViewRepresentable: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void
    
    func makeUIViewController(context: Context) -> MultiShotCameraViewController {
        let vc = MultiShotCameraViewController()
        vc.onCapture = onCapture
        vc.onCancel = onCancel
        return vc
    }
    
    func updateUIViewController(_ uiViewController: MultiShotCameraViewController, context: Context) {}
}

final class MultiShotCameraViewController: UIViewController {
    var onCapture: ((UIImage) -> Void)?
    var onCancel: (() -> Void)?
    
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "doseluma.multishot")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupUI()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { self.session.stopRunning() }
    }
    
    private func setupCamera() {
        session.sessionPreset = .photo
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        
        session.addInput(input)
        
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
        
        sessionQueue.async { self.session.startRunning() }
    }
    
    private func setupUI() {
        // Capture button
        let captureButton = UIButton(type: .system)
        captureButton.setImage(UIImage(systemName: "camera.circle.fill"), for: .normal)
        captureButton.tintColor = .white
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.contentVerticalAlignment = .fill
        captureButton.contentHorizontalAlignment = .fill
        captureButton.imageView?.contentMode = .scaleAspectFit
        captureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        view.addSubview(captureButton)
        
        NSLayoutConstraint.activate([
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            captureButton.widthAnchor.constraint(equalToConstant: 70),
            captureButton.heightAnchor.constraint(equalToConstant: 70),
        ])
    }
    
    @objc private func captureTapped() {
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .auto
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

extension MultiShotCameraViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        
        // Provide haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        // Flash animation
        let flashView = UIView(frame: view.bounds)
        flashView.backgroundColor = .white
        flashView.alpha = 0.8
        view.addSubview(flashView)
        UIView.animate(withDuration: 0.2) {
            flashView.alpha = 0
        } completion: { _ in
            flashView.removeFromSuperview()
        }
        
        onCapture?(image)
    }
}

// MARK: - Camera Wrapper View (keep existing single-shot for backward compatibility)

private struct OCRCameraWrapperView: UIViewControllerRepresentable {
    @Binding var detectedText: String?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIViewController {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            return makeDataScanner()
        } else {
            return makeVisionScanner()
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    // MARK: DataScanner path

    private func makeDataScanner() -> UIViewController {
        let vc = DataScannerWrapperViewController()
        vc.onDetected = { text in
            detectedText = text
            dismiss()
        }
        vc.onCancel = { dismiss() }
        return vc
    }

    // MARK: Vision fallback path

    private func makeVisionScanner() -> OCRCameraViewController {
        let vc = OCRCameraViewController()
        vc.onDetected = { text in
            detectedText = text
            dismiss()
        }
        vc.onCancel = { dismiss() }
        return vc
    }
}

// MARK: - DataScannerViewController wrapper
//
// Uses VisionKit's DataScannerViewController for live word-level highlight
// overlays. A "Capture" button locks the current recognised items and returns
// their text; Cancel dismisses without returning anything.

final class DataScannerWrapperViewController: UIViewController, DataScannerViewControllerDelegate {
    var onDetected: ((String) -> Void)?
    var onCancel:   (() -> Void)?

    private var scanner: DataScannerViewController?
    private var latestItems: [RecognizedItem] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupScanner()
        setupControls()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner?.stopScanning()
    }

    // MARK: Scanner setup

    private func setupScanner() {
        // .barCode() lets DataScanner pick up GS1-128 / EAN-13 / Code-128
        // barcodes on medication packaging.  The barcode payload often encodes
        // the NDC directly, which BarcodeNDCIdentifier can extract.
        let sc = DataScannerViewController(
            recognizedDataTypes: [.text(), .barcode()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        sc.delegate = self
        addChild(sc)
        sc.view.frame = view.bounds
        sc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sc.view)
        sc.didMove(toParent: self)
        self.scanner = sc
        try? sc.startScanning()
    }

    // MARK: Overlay controls

    private func setupControls() {
        // Cancel button (top-right)
        let cancelBtn = UIButton(type: .system)
        cancelBtn.setTitle("Cancel", for: .normal)
        cancelBtn.setTitleColor(.white, for: .normal)
        cancelBtn.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancelBtn.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        cancelBtn.layer.cornerRadius = 14
        var cancelConfig = UIButton.Configuration.plain()
        cancelConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        cancelBtn.configuration = cancelConfig
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        cancelBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        // Capture button (bottom-centre)
        let captureBtn = UIButton(type: .system)
        captureBtn.setTitle("Capture", for: .normal)
        captureBtn.setTitleColor(.black, for: .normal)
        captureBtn.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        captureBtn.backgroundColor = .white
        captureBtn.layer.cornerRadius = 28
        captureBtn.translatesAutoresizingMaskIntoConstraints = false
        captureBtn.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)

        // Torch toggle button (top-left)
        let torchBtn = UIButton(type: .system)
        torchBtn.setImage(UIImage(systemName: "bolt.fill"), for: .normal)
        torchBtn.tintColor = .white
        torchBtn.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        torchBtn.layer.cornerRadius = 20
        torchBtn.translatesAutoresizingMaskIntoConstraints = false
        torchBtn.addTarget(self, action: #selector(torchTapped), for: .touchUpInside)

        view.addSubview(cancelBtn)
        view.addSubview(captureBtn)
        view.addSubview(torchBtn)

        NSLayoutConstraint.activate([
            cancelBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancelBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            captureBtn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            captureBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureBtn.widthAnchor.constraint(equalToConstant: 130),
            captureBtn.heightAnchor.constraint(equalToConstant: 56),

            torchBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            torchBtn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            torchBtn.widthAnchor.constraint(equalToConstant: 40),
            torchBtn.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    // MARK: Actions

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func captureTapped() {
        // Collect both OCR text and barcode payloads (barcodes on packaging
        // often encode NDC directly, which the DIN/NDC regex can then extract).
        let text: String = latestItems.compactMap { item -> String? in
            switch item {
            case .text(let t):    return t.transcript
            case .barcode(let b): return b.payloadStringValue
            @unknown default:     return nil
            }
        }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onDetected?(text)
    }

    private var torchOn = false
    @objc private func torchTapped() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        torchOn.toggle()
        try? device.lockForConfiguration()
        device.torchMode = torchOn ? .on : .off
        device.unlockForConfiguration()
    }

    // MARK: DataScannerViewControllerDelegate
    // No-op — we collect items on demand via captureTapped.
    func dataScanner(_ dataScanner: DataScannerViewController,
                     didAdd addedItems: [RecognizedItem],
                     allItems: [RecognizedItem]) {
        latestItems = allItems
    }

    func dataScanner(_ dataScanner: DataScannerViewController,
                     didUpdate updatedItems: [RecognizedItem],
                     allItems: [RecognizedItem]) {
        latestItems = allItems
    }

    func dataScanner(_ dataScanner: DataScannerViewController,
                     didRemove removedItems: [RecognizedItem],
                     allItems: [RecognizedItem]) {
        latestItems = allItems
    }
}

// MARK: - Vision + AVCapture fallback
//
// Used when DataScannerViewController is unavailable.
// Improvements over the original implementation:
//   • 0.5 s inter-frame throttle — doesn't hammer Vision on every frame.
//   • ROI cropping — only the viewfinder rectangle is analysed (reduces false
//     positives from the camera UI chrome and background).
//   • Confidence threshold (≥ 0.4) to drop low-quality candidates.
//   • Deduplication of identical lines within a result.
//   • Manual "Capture" button rather than auto-fire — user controls when text
//     is accepted.
//   • Torch toggle.

final class OCRCameraViewController: UIViewController {
    var onDetected: ((String) -> Void)?
    var onCancel:   (() -> Void)?

    private let session       = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let bufferDelegate = OCRBufferDelegate()
    private let sessionQueue   = DispatchQueue(label: "doseluma.session")

    // The viewfinder rect in view coordinates — set in viewDidLayoutSubviews
    private var finderRect: CGRect = .zero
    private var torchOn = false

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupOverlay()

        bufferDelegate.onText = { [weak self] text in
            self?.latestText = text
        }
    }

    private var latestText: String?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds

        // Keep finderRect in sync with the overlay finder view position.
        // Tag 99 is set on the finder UIView in setupOverlay.
        if let finder = view.viewWithTag(99) {
            finderRect = finder.frame
            bufferDelegate.finderRect  = finderRect
            bufferDelegate.viewBounds  = view.bounds
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { self.session.stopRunning() }
    }

    // MARK: Camera setup

    private func setupCamera() {
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input  = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(bufferDelegate, queue: DispatchQueue(label: "doseluma.ocr"))
        if session.canAddOutput(output) { session.addOutput(output) }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        sessionQueue.async { self.session.startRunning() }
    }

    // MARK: Overlay UI

    private func setupOverlay() {
        // Dark vignette — everything outside the finder is dimmed
        let dimOverlay = ScannerDimView()
        dimOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dimOverlay)

        // Viewfinder rectangle
        let finder = UIView()
        finder.tag = 99
        finder.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        finder.layer.borderWidth  = 2
        finder.layer.cornerRadius = 10
        finder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(finder)

        // Corner accent marks
        addCornerMarks(to: finder)

        // Instruction label
        let instruction = UILabel()
        instruction.text = "Point camera at medication label"
        instruction.textColor  = .white
        instruction.font       = .systemFont(ofSize: 15, weight: .medium)
        instruction.textAlignment = .center
        instruction.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        instruction.layer.cornerRadius = 8
        instruction.clipsToBounds = true
        instruction.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instruction)

        // Cancel button
        let cancelBtn = UIButton(type: .system)
        cancelBtn.setTitle("Cancel", for: .normal)
        cancelBtn.setTitleColor(.white, for: .normal)
        cancelBtn.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancelBtn.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        cancelBtn.layer.cornerRadius = 14
        var cancelConfig = UIButton.Configuration.plain()
        cancelConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        cancelBtn.configuration = cancelConfig
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        cancelBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancelBtn)

        // Capture button
        let captureBtn = UIButton(type: .system)
        captureBtn.setTitle("Capture", for: .normal)
        captureBtn.setTitleColor(.black, for: .normal)
        captureBtn.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        captureBtn.backgroundColor = .white
        captureBtn.layer.cornerRadius = 28
        captureBtn.translatesAutoresizingMaskIntoConstraints = false
        captureBtn.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        view.addSubview(captureBtn)

        // Torch button
        let torchBtn = UIButton(type: .system)
        torchBtn.setImage(UIImage(systemName: "bolt.fill"), for: .normal)
        torchBtn.tintColor  = .white
        torchBtn.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        torchBtn.layer.cornerRadius = 20
        torchBtn.translatesAutoresizingMaskIntoConstraints = false
        torchBtn.addTarget(self, action: #selector(torchTapped), for: .touchUpInside)
        view.addSubview(torchBtn)

        NSLayoutConstraint.activate([
            dimOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            dimOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            finder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            finder.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            finder.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.88),
            finder.heightAnchor.constraint(equalToConstant: 180),

            instruction.topAnchor.constraint(equalTo: finder.bottomAnchor, constant: 14),
            instruction.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instruction.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            instruction.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            cancelBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancelBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            captureBtn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            captureBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureBtn.widthAnchor.constraint(equalToConstant: 130),
            captureBtn.heightAnchor.constraint(equalToConstant: 56),

            torchBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            torchBtn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            torchBtn.widthAnchor.constraint(equalToConstant: 40),
            torchBtn.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    /// Adds four L-shaped corner marks inside the finder view.
    private func addCornerMarks(to finder: UIView) {
        let len: CGFloat = 18
        let thickness: CGFloat = 3
        let color = UIColor.systemYellow.cgColor
        let r: CGFloat = 10

        let positions: [(CGFloat, CGFloat)] = [(0,0),(1,0),(0,1),(1,1)]
        for (hEdge, vEdge) in positions {
            let h = CALayer()
            h.backgroundColor = color
            h.frame = CGRect(x: hEdge == 0 ? r : -r - len + finder.bounds.width,
                             y: vEdge == 0 ? r : finder.bounds.height - r - thickness,
                             width: len, height: thickness)

            let v = CALayer()
            v.backgroundColor = color
            v.frame = CGRect(x: hEdge == 0 ? r : finder.bounds.width - r - thickness,
                             y: vEdge == 0 ? r : -r - len + finder.bounds.height,
                             width: thickness, height: len)

            // Defer to after layout
            DispatchQueue.main.async {
                let bw = finder.bounds.width
                let bh = finder.bounds.height
                h.frame = CGRect(
                    x: hEdge == 0 ? r : bw - r - len,
                    y: vEdge == 0 ? r : bh - r - thickness,
                    width: len, height: thickness)
                v.frame = CGRect(
                    x: hEdge == 0 ? r : bw - r - thickness,
                    y: vEdge == 0 ? r : bh - r - len,
                    width: thickness, height: len)
                finder.layer.addSublayer(h)
                finder.layer.addSublayer(v)
            }
        }
    }

    // MARK: Actions

    @objc private func cancelTapped() { onCancel?() }

    @objc private func captureTapped() {
        guard let text = latestText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Flash the instruction label if nothing detected yet
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onDetected?(text)
    }

    @objc private func torchTapped() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        torchOn.toggle()
        try? device.lockForConfiguration()
        device.torchMode = torchOn ? .on : .off
        device.unlockForConfiguration()
    }
}

// MARK: - Dim overlay (everything outside the finder box is darker)

private final class ScannerDimView: UIView {
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        UIColor.black.withAlphaComponent(0.52).setFill()
        ctx.fill(rect)
    }
}

// MARK: - Vision OCR buffer delegate
//
// Runs on a dedicated background queue. Throttles to one Vision request every
// 0.5 s, crops the pixel buffer to the finder rect to reduce noise, filters
// observations by confidence, and deduplicates output lines.

private final class OCRBufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onText: ((String) -> Void)?

    /// The viewfinder rectangle in UIKit view coordinates.
    var finderRect: CGRect = .zero
    /// The full view bounds, used to normalise the ROI.
    var viewBounds: CGRect = .zero

    private var isProcessing = false
    private var lastProcessed: Date = .distantPast
    private let throttleInterval: TimeInterval = 0.5

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !isProcessing else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= throttleInterval else { return }
        isProcessing  = true
        lastProcessed = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            isProcessing = false
            return
        }

        let request = VNRecognizeTextRequest { [weak self] req, _ in
            defer { self?.isProcessing = false }
            guard let obs = req.results as? [VNRecognizedTextObservation] else { return }

            let lines: [String] = obs
                .filter { $0.confidence >= 0.4 }
                .compactMap { $0.topCandidates(1).first?.string }

            // Deduplicate while preserving order
            var seen = Set<String>()
            let deduped = lines.filter { seen.insert($0).inserted }

            let text = deduped.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self?.onText?(text)
        }

        request.recognitionLevel       = .accurate
        request.usesLanguageCorrection = false   // drug names confuse autocorrect
        request.minimumTextHeight      = 0.012   // slightly lower to catch more text
        request.recognitionLanguages   = ["en-US"]  // optimize for English
        request.automaticallyDetectsLanguage = true  // better accuracy

        // Crop to finder rect in normalised Vision coordinates (origin bottom-left).
        if finderRect != .zero && viewBounds != .zero {
            let vw = viewBounds.width
            let vh = viewBounds.height
            let roiX      = finderRect.minX / vw
            let roiY      = 1.0 - (finderRect.maxY / vh)   // Vision Y is flipped
            let roiWidth  = finderRect.width  / vw
            let roiHeight = finderRect.height / vh
            request.regionOfInterest = CGRect(x: roiX, y: roiY, width: roiWidth, height: roiHeight)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .right,  // landscape-corrected
                                            options: [:])
        try? handler.perform([request])
    }
}
