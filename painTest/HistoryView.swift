import SwiftUI

/// Kept for previews / compatibility; the app uses `LogView`’s History section.
struct HistoryView: View {
    var body: some View {
        LogView()
    }
}

#Preview {
    HistoryView()
        .environmentObject(PainStore())
}
