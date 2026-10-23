import SwiftUI

struct EntryRow: View {
    let entry: PainEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)
                if !entry.notes.isEmpty {
                    Text(entry.notes)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            PainValueLabel(value: entry.value, size: .body)
                .animation(AppAnimations.quick, value: entry.value)
        }
    }
}

struct EntryDeleteAlertModifier: ViewModifier {
    @EnvironmentObject var store: PainStore
    @Binding var entry: PainEntry?

    func body(content: Content) -> some View {
        content
            .alert("Delete entry?", isPresented: Binding(
                get: { entry != nil },
                set: { if !$0 { entry = nil } }
            )) {
                Button("Cancel", role: .cancel) {
                    entry = nil
                }
                Button("Delete", role: .destructive) {
                    if let entry {
                        store.deleteEntry(entry)
                    }
                    self.entry = nil
                }
            } message: {
                Text("This entry will be removed from this device.")
            }
    }
}

extension View {
    func entryDeleteAlert(entry: Binding<PainEntry?>) -> some View {
        modifier(EntryDeleteAlertModifier(entry: entry))
    }
}
