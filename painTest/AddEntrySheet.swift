import SwiftUI

struct AddEntrySheet: View {
    @EnvironmentObject var store: PainStore
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var value: Double = 5
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    painValueSection
                        .staggeredAppear(index: 0)
                    dateSection
                        .staggeredAppear(index: 1)
                    notesSection
                        .staggeredAppear(index: 2)
                    saveButton
                        .staggeredAppear(index: 3)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("Add pain entry")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(.body)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
    }

    private var painValueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pain level (0–10)")
                .font(.title3.weight(.semibold))

            Text(PainFormatting.format(value))
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentTransition(.numericText())
                .animation(AppAnimations.quick, value: value)

            Slider(value: $value, in: 0...10, step: 1)
                .tint(.indigo)

            Text("0 = no pain · 10 = worst pain")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Date")
                .font(.title3.weight(.semibold))

            DatePicker(
                "Date",
                selection: $date,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes (optional)")
                .font(.title3.weight(.semibold))

            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .lineLimit(3...6)
                .font(.body)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
        }
    }

    private var saveButton: some View {
        Button(action: save) {
            Text("Save entry")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.indigo)
        .pressableButtonStyle()
        .padding(.top, 8)
    }

    private func save() {
        store.addEntry(
            date: date,
            value: value,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        dismiss()
    }
}

#Preview {
    AddEntrySheet()
        .environmentObject(PainStore())
}
