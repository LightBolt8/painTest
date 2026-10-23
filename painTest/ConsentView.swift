import SwiftUI

/// First-launch consent and privacy notice. Also reachable from Settings for review.
struct ConsentView: View {
    static let storageKey = "consent_v1_accepted"

    var isReview = false
    var onDone: () -> Void

    @AppStorage(ConsentView.storageKey) private var consentAccepted = false
    @State private var confirmed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 44))
                        .foregroundStyle(.indigo)

                    Text("Before you start")
                        .font(.largeTitle.bold())

                    point(
                        "camera.fill",
                        "What’s collected",
                        "Face photos you take or upload, the facial action units OpenFace measures, and any pain ratings or notes you add."
                    )
                    point(
                        "desktopcomputer",
                        "Where photos go",
                        "Photos are sent to the OpenFace bridge on your own Mac. On the same Wi‑Fi they stay on your local network. Away from home they travel over an encrypted Cloudflare tunnel to your Mac."
                    )
                    point(
                        "iphone",
                        "What’s stored",
                        "Results, small thumbnails, and your notes are saved only on this device, protected by its passcode. Nothing is uploaded to any other server."
                    )
                    point(
                        "stethoscope",
                        "Not a medical device",
                        "The PSPI score is an automated estimate for research and self-tracking. It isn’t a diagnosis. Talk to a clinician about your pain."
                    )
                    point(
                        "trash",
                        "You’re in control",
                        "Delete single captures in Log, or everything at once in Settings → Delete all data."
                    )
                    point(
                        "person.2",
                        "Using this in a study?",
                        "If you collect photos from other people, get their informed consent and any required ethics (IRB) approval first."
                    )

                    if !isReview {
                        Toggle(isOn: $confirmed) {
                            Text("I understand and agree to how my photos and data are used.")
                                .font(.subheadline)
                        }
                        .toggleStyle(.switch)
                        .padding(.top, 4)
                    }
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                if !isReview {
                    Button {
                        consentAccepted = true
                        onDone()
                    } label: {
                        Text("Continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .controlSize(.large)
                    .disabled(!confirmed)
                    .padding()
                    .background(.bar)
                }
            }
            .toolbar {
                if isReview {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
            }
        }
        .interactiveDismissDisabled(!isReview)
    }

    private func point(_ systemImage: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.indigo)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    ConsentView { }
}
