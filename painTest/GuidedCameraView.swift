import AVFoundation
import Combine
import SwiftUI
import Vision
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit) && !os(macOS)

/// Live framing quality from Vision (pre-OpenFace).
struct LiveFramingHint: Equatable {
    enum Status: Equatable {
        case noFace
        case adjust
        case ready
    }

    var status: Status = .noFace
    var yawDegrees: Double?
    var quality: Double?
    var message: String = "Position your face in the oval"

    var yawLabel: String {
        guard let yawDegrees else { return "—" }
        return String(format: "%.0f°", yawDegrees)
    }

    var qualityLabel: String {
        guard let quality else { return "—" }
        return String(format: "%.0f%%", quality * 100)
    }
}

@MainActor
final class GuidedCameraController: NSObject, ObservableObject {
    @Published var hint = LiveFramingHint()
    @Published var authorizationDenied = false
    @Published var isRunning = false
    @Published var flash = false

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "painTest.guidedCamera.session")
    private let visionQueue = DispatchQueue(label: "painTest.guidedCamera.vision")
    private var photoContinuation: CheckedContinuation<Data, Error>?
    private var isCapturing = false
    private var lastVisionTime: CFTimeInterval = 0

    private let maxAbsYaw: Double = 45
    private let minQuality: Double = 0.2

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        self?.configureAndStart()
                    } else {
                        self?.authorizationDenied = true
                    }
                }
            }
        default:
            authorizationDenied = true
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            Task { @MainActor in self.isRunning = false }
        }
    }

    func captureJPEG() async throws -> Data {
        guard !isCapturing else {
            throw CaptureError.busy
        }
        isCapturing = true
        defer { isCapturing = false }

        flash = true
        try? await Task.sleep(nanoseconds: 80_000_000)

        return try await withCheckedThrowingContinuation { continuation in
            photoContinuation = continuation
            let settings: AVCapturePhotoSettings
            if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else {
                self.session.commitConfiguration()
                Task { @MainActor in self.authorizationDenied = true }
                return
            }
            self.session.addInput(input)

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }

            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.setSampleBufferDelegate(self, queue: self.visionQueue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            if let connection = self.videoOutput.connection(with: .video) {
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }

            self.session.commitConfiguration()
            self.session.startRunning()
            Task { @MainActor in self.isRunning = true }
        }
    }

    private func updateHint(from observation: VNFaceObservation?) {
        guard let observation else {
            hint = LiveFramingHint(
                status: .noFace,
                yawDegrees: nil,
                quality: nil,
                message: "Position your face in the oval"
            )
            return
        }

        let yawRad = observation.yaw?.doubleValue
        let yawDeg = yawRad.map { $0 * 180 / .pi }
        let quality = observation.faceCaptureQuality.map(Double.init)
        let box = observation.boundingBox

        // Vision box is normalized, origin bottom-left. Oval is centered ~0.5,0.52 with size ~0.62×0.78.
        let centerX = box.midX
        let centerY = box.midY
        let centered =
            abs(centerX - 0.5) < 0.18
            && abs(centerY - 0.52) < 0.2
        let sized = box.width > 0.18 && box.width < 0.85

        var issues: [String] = []
        if !centered { issues.append("Center your face") }
        if box.width < 0.18 { issues.append("Move closer") }
        if box.width > 0.85 { issues.append("Move back") }
        if let yawDeg, abs(yawDeg) > maxAbsYaw {
            issues.append(abs(yawDeg) > 60 ? "Face the camera" : "Turn toward camera")
        }
        if let quality, quality < minQuality {
            issues.append("Improve lighting")
        }

        let yawOK = yawDeg.map { abs($0) <= maxAbsYaw } ?? true
        let qualityOK = quality.map { $0 >= minQuality } ?? true
        let ready = centered && sized && yawOK && qualityOK

        hint = LiveFramingHint(
            status: ready ? .ready : .adjust,
            yawDegrees: yawDeg,
            quality: quality,
            message: ready ? "Looking good — hold still" : (issues.first ?? "Adjust framing")
        )
    }

    enum CaptureError: LocalizedError {
        case busy
        case noImage

        var errorDescription: String? {
            switch self {
            case .busy: return "Camera is busy."
            case .noImage: return "Could not capture a photo."
            }
        }
    }
}

extension GuidedCameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        Task { @MainActor in
            flash = false
            if let error {
                photoContinuation?.resume(throwing: error)
                photoContinuation = nil
                return
            }
            guard let data = photo.fileDataRepresentation() else {
                photoContinuation?.resume(throwing: CaptureError.noImage)
                photoContinuation = nil
                return
            }
            photoContinuation?.resume(returning: data)
            photoContinuation = nil
        }
    }
}

extension GuidedCameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        // Throttle Vision ~8fps
        // Access lastVisionTime carefully — use a local gate via objc associated or skip if too soon.
        // We'll check on vision queue with a static-ish pattern via MainActor read is awkward;
        // use atomic-ish: process every frame but request is light enough at 8fps via time check on vision queue.
        // Store time on vision queue only:
        struct Gate {
            static var last: CFTimeInterval = 0
        }
        if now - Gate.last < 0.12 { return }
        Gate.last = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceRectanglesRequest()
        // Prefer quality when available (fills faceCaptureQuality).
        let qualityRequest = VNDetectFaceCaptureQualityRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored, options: [:])
        do {
            try handler.perform([request, qualityRequest])
            let qualityFace = qualityRequest.results?.first
            let rectFace = request.results?.first
            let best = qualityFace ?? rectFace
            // Merge yaw from rect if quality observation lacks it
            Task { @MainActor in
                if qualityFace != nil, qualityFace?.yaw == nil, rectFace?.yaw != nil {
                    self.updateHintMerged(rect: rectFace, quality: qualityFace)
                } else {
                    self.updateHint(from: best)
                }
            }
        } catch {
            Task { @MainActor in
                self.updateHint(from: nil)
            }
        }
    }
}

private extension GuidedCameraController {
    func updateHintMerged(rect: VNFaceObservation?, quality: VNFaceObservation?) {
        guard let quality else {
            updateHint(from: rect)
            return
        }
        // Build hint using quality's box + quality score, yaw from rect if needed
        let yawRad = quality.yaw?.doubleValue ?? rect?.yaw?.doubleValue
        let yawDeg = yawRad.map { $0 * 180 / .pi }
        let q = quality.faceCaptureQuality.map(Double.init) ?? rect?.faceCaptureQuality.map(Double.init)
        let box = quality.boundingBox

        let centerX = box.midX
        let centerY = box.midY
        let centered = abs(centerX - 0.5) < 0.18 && abs(centerY - 0.52) < 0.2
        let sized = box.width > 0.18 && box.width < 0.85

        var issues: [String] = []
        if !centered { issues.append("Center your face") }
        if box.width < 0.18 { issues.append("Move closer") }
        if box.width > 0.85 { issues.append("Move back") }
        if let yawDeg, abs(yawDeg) > maxAbsYaw {
            issues.append(abs(yawDeg) > 60 ? "Face the camera" : "Turn toward camera")
        }
        if let q, q < minQuality {
            issues.append("Improve lighting")
        }

        let yawOK = yawDeg.map { abs($0) <= maxAbsYaw } ?? true
        let qualityOK = q.map { $0 >= minQuality } ?? true
        let ready = centered && sized && yawOK && qualityOK

        hint = LiveFramingHint(
            status: ready ? .ready : .adjust,
            yawDegrees: yawDeg,
            quality: q,
            message: ready ? "Looking good — hold still" : (issues.first ?? "Adjust framing")
        )
    }
}

// MARK: - Preview layer

struct CameraPreviewRepresentable: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Guided camera UI

struct GuidedCameraView: View {
    var onCancel: () -> Void
    var onCaptured: (Data) -> Void

    @StateObject private var camera = GuidedCameraController()
    @State private var isShutterBusy = false
    @State private var captureError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewRepresentable(session: camera.session)
                .ignoresSafeArea()

            if camera.flash {
                Color.white.opacity(0.35).ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            FaceOvalOverlay(status: camera.hint.status)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                hintsPanel
                shutterBar
            }
        }
        .statusBarHidden(true)
        .sensoryFeedback(.success, trigger: camera.hint.status) { old, new in
            new == .ready && old != .ready
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .alert("Camera", isPresented: Binding(
            get: { captureError != nil || camera.authorizationDenied },
            set: { if !$0 { captureError = nil } }
        )) {
            Button("OK", role: .cancel) {
                if camera.authorizationDenied { onCancel() }
                captureError = nil
            }
        } message: {
            Text(
                camera.authorizationDenied
                    ? "Camera access is required. Enable it in Settings."
                    : (captureError ?? "")
            )
        }
    }

    private var topBar: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.35), in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var hintsPanel: some View {
        VStack(spacing: 10) {
            Text(camera.hint.message)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(hintBackground, in: Capsule())
                .animation(.easeInOut(duration: 0.2), value: camera.hint.message)

            HStack(spacing: 16) {
                metricChip(title: "Yaw", value: camera.hint.yawLabel, ok: yawOK)
                metricChip(title: "Quality", value: camera.hint.qualityLabel, ok: qualityOK)
            }
        }
        .padding(.bottom, 20)
    }

    private var yawOK: Bool {
        guard let yaw = camera.hint.yawDegrees else { return camera.hint.status != .noFace }
        return abs(yaw) <= 45
    }

    private var qualityOK: Bool {
        guard let q = camera.hint.quality else { return camera.hint.status == .ready }
        return q >= 0.2
    }

    private var hintBackground: Color {
        switch camera.hint.status {
        case .ready: return .green.opacity(0.75)
        case .adjust: return .orange.opacity(0.8)
        case .noFace: return .black.opacity(0.55)
        }
    }

    private func metricChip(title: String, value: String, ok: Bool) -> some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(value)
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(ok ? Color.white : Color.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var shutterBar: some View {
        HStack {
            Spacer()
            Button {
                Task { await takePhoto() }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 78, height: 78)
                    Circle()
                        .fill(camera.hint.status == .ready ? Color.white : Color.white.opacity(0.85))
                        .frame(width: 64, height: 64)
                }
            }
            .disabled(isShutterBusy || camera.authorizationDenied)
            .accessibilityLabel("Take photo")
            Spacer()
        }
        .padding(.bottom, 36)
    }

    @MainActor
    private func takePhoto() async {
        isShutterBusy = true
        defer { isShutterBusy = false }
        do {
            let data = try await camera.captureJPEG()
            // Don't stop the session here — stopping blanks the preview before dismiss
            // and stacks with the review cover, which looked like a stuck black screen.
            onCaptured(data)
        } catch {
            captureError = error.localizedDescription
        }
    }
}

struct FaceOvalOverlay: View {
    let status: LiveFramingHint.Status

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * 0.72
            let h = w * 1.28
            let rect = CGRect(
                x: (geo.size.width - w) / 2,
                y: (geo.size.height - h) / 2 - geo.size.height * 0.04,
                width: w,
                height: h
            )

            ZStack {
                // Dim outside oval
                Rectangle()
                    .fill(Color.black.opacity(0.42))
                    .mask(
                        ZStack {
                            Rectangle().fill(Color.white)
                            Ellipse()
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    )

                Ellipse()
                    .stroke(ovalColor, style: StrokeStyle(lineWidth: 3, dash: status == .ready ? [] : [10, 7]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .shadow(color: ovalColor.opacity(0.5), radius: status == .ready ? 8 : 0)
                    .animation(.easeInOut(duration: 0.25), value: status)
            }
        }
        .ignoresSafeArea()
    }

    private var ovalColor: Color {
        switch status {
        case .ready: return .green
        case .adjust: return .orange
        case .noFace: return .white.opacity(0.85)
        }
    }
}

#endif
