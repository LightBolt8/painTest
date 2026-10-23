import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Review a pending capture before OpenFace upload. Supports retake and compare-with-last.
struct CaptureReviewView: View {
    let pendingJPEG: Data
    let lastGood: LastCaptureStore.Snapshot?
    var analyzeTitle: String = "Analyze"
    var onRetake: () -> Void
    var onConfirm: (Data) -> Void
    var onCancel: () -> Void

    @State private var showingLast = false

    private var displayedJPEG: Data {
        if showingLast, let lastGood {
            return lastGood.jpeg
        }
        return pendingJPEG
    }

    private var isShowingLast: Bool {
        showingLast && lastGood != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                imagePreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))

                controls
                    .padding()
                    .background(.bar)
            }
            .background(Color(.systemBackground))
            .navigationTitle(isShowingLast ? "Last good" : "Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private var imagePreview: some View {
        ZStack {
            if let image = decodedImage(from: displayedJPEG) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
                    .animation(.easeInOut(duration: 0.2), value: showingLast)
            } else {
                ContentUnavailableView(
                    "Couldn’t show preview",
                    systemImage: "photo",
                    description: Text("You can still analyze or retake.")
                )
            }

            VStack {
                if let lastGood, showingLast {
                    metaBanner(lastGood)
                }
                Spacer()
            }
            .padding(.top, 8)
        }
    }

    #if canImport(UIKit)
    private func decodedImage(from data: Data) -> PlatformImage? {
        guard let image = UIImage(data: data) else { return nil }
        // Normalize orientation so review isn’t a blank/wrong-aspect draw.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
    #else
    private func decodedImage(from data: Data) -> PlatformImage? {
        PlatformImage(data: data)
    }
    #endif

    private func metaBanner(_ snap: LastCaptureStore.Snapshot) -> some View {
        HStack(spacing: 10) {
            if let pspi = snap.meta.pspi {
                Text(String(format: "PSPI %.1f", pspi))
                    .fontWeight(.semibold)
            }
            Text(snap.meta.date.formatted(date: .abbreviated, time: .shortened))
            if let yaw = snap.meta.yawDegrees {
                Text(String(format: "yaw %.0f°", yaw))
            }
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if lastGood != nil {
                Picker("View", selection: $showingLast) {
                    Text("New").tag(false)
                    Text("Last good").tag(true)
                }
                .pickerStyle(.segmented)

                Text(showingLast
                     ? "Previous successful capture — re-analyze without a new photo."
                     : "New capture — retake anytime before analyzing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Retake if framing looks off. Analyze sends this photo to OpenFace.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button {
                    onRetake()
                } label: {
                    Label("Retake", systemImage: "camera.rotate")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    if isShowingLast, let lastGood {
                        onConfirm(lastGood.jpeg)
                    } else {
                        onConfirm(pendingJPEG)
                    }
                } label: {
                    Label(
                        isShowingLast ? "Re-analyze last" : analyzeTitle,
                        systemImage: "checkmark.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.large)
            }
        }
    }
}

#Preview {
    CaptureReviewView(
        pendingJPEG: Data(),
        lastGood: nil,
        onRetake: {},
        onConfirm: { _ in },
        onCancel: {}
    )
}
