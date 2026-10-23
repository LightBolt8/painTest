import SwiftUI

struct AgePreviewView: View {
    let originalData: Data
    let agedData: Data
    let direction: Int

    @State private var showAged = true

    private var label: String {
        if direction < 0 { return "Younger (\(direction))" }
        if direction > 0 { return "Older (+\(direction))" }
        return "Unchanged (0)"
    }

    var body: some View {
        VStack(spacing: 16) {
            Picker("View", selection: $showAged) {
                Text("Original").tag(false)
                Text("Aged").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Text(showAged ? label : "Original photo")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let image = PlatformImage(data: showAged ? agedData : originalData) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal)
                    .animation(.easeInOut(duration: 0.2), value: showAged)
            } else {
                ContentUnavailableView("Couldn’t show image", systemImage: "photo")
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .navigationTitle("Age preview")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AgePreviewView(
            originalData: Data(),
            agedData: Data(),
            direction: -60
        )
    }
}
