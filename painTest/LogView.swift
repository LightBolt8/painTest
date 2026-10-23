import SwiftUI

/// Combined History + Trends tab.
struct LogView: View {
    @EnvironmentObject var store: PainStore
    @State private var section: Section = .history

    private enum Section: String, CaseIterable, Identifiable {
        case history
        case trends

        var id: String { rawValue }

        var title: String {
            switch self {
            case .history: return "History"
            case .trends: return "Trends"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                Group {
                    switch section {
                    case .history:
                        HistoryContent()
                    case .trends:
                        TrendsContent()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(
                        item: SessionCSVExport(
                            sessions: store.sessions,
                            neutralPhotoPSPI: NeutralBaselineStore.shared.baseline?.photoPSPI,
                            neutralDeaged: NeutralBaselineStore.shared.baseline?.deaged
                        ),
                        preview: SharePreview("painTest sessions (\(store.sessions.count))")
                    ) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.sessions.isEmpty)
                }
            }
            .animation(AppAnimations.quick, value: section)
        }
    }
}

/// History list without its own NavigationStack (embedded in LogView).
private struct HistoryContent: View {
    @EnvironmentObject var store: PainStore
    @State private var sessionPendingDelete: AnalysisSession?

    private var groupIDs: [Date] {
        store.sessionMonthlyGroups.map(\.monthStart)
    }

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No history yet", systemImage: "face.smiling")
                } description: {
                    Text("Capture a face photo to save an Action Units session here.")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                List {
                    ForEach(Array(store.sessionMonthlyGroups.enumerated()), id: \.element.id) { groupIndex, group in
                        Section {
                            ForEach(Array(group.sessions.enumerated()), id: \.element.id) { entryIndex, session in
                                NavigationLink {
                                    SessionDetailView(session: session)
                                } label: {
                                    SessionRow(session: session)
                                }
                                .staggeredAppear(index: min(groupIndex + entryIndex, 12))
                                .transition(AppAnimations.insertionTransition)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        sessionPendingDelete = session
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        sessionPendingDelete = session
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.monthStart.formatted(.dateTime.month(.wide).year()))
                                Spacer()
                                HStack(spacing: 4) {
                                    Text("\(group.sessions.count) \(group.sessions.count == 1 ? "capture" : "captures")")
                                    if let avg = group.averagePSPI {
                                        Text("• avg PSPI \(String(format: "%.1f", avg))")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .transition(.opacity)
            }
        }
        .animation(AppAnimations.smooth, value: store.sessions.isEmpty)
        .animation(AppAnimations.list, value: groupIDs)
        .sessionDeleteAlert(session: $sessionPendingDelete)
    }
}

struct SessionRow: View {
    let session: AnalysisSession

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    if session.faceFound {
                        Text("est. PSPI \(String(format: "%.1f", session.pspi))")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.indigo)
                    } else {
                        Text("Face not found")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    if let pain = session.selfReportedPain {
                        Text("· You \(pain)/10")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    if session.faceFound && !session.passedStrictChecks {
                        Label("Low confidence", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if session.agedBeforeAnalysis {
                        Label("Aged", systemImage: "wand.and.stars")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !session.notes.isEmpty {
                        Image(systemName: "note.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = session.thumbnailJPEG,
           let image = PlatformImage(data: data) {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "face.dashed")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

struct SessionDetailView: View {
    let session: AnalysisSession

    var body: some View {
        ActionUnitsView(
            analysis: session.asAnalysis(),
            capturedAt: session.date,
            agedBeforeAnalysis: session.agedBeforeAnalysis,
            sessionID: session.id
        )
    }
}

private struct SessionDeleteAlertModifier: ViewModifier {
    @EnvironmentObject var store: PainStore
    @Binding var session: AnalysisSession?

    func body(content: Content) -> some View {
        content
            .alert("Delete capture?", isPresented: Binding(
                get: { session != nil },
                set: { if !$0 { session = nil } }
            )) {
                Button("Cancel", role: .cancel) {
                    session = nil
                }
                Button("Delete", role: .destructive) {
                    if let session {
                        store.deleteSession(session)
                    }
                    self.session = nil
                }
            } message: {
                Text("This capture will be removed from this device.")
            }
    }
}

private extension View {
    func sessionDeleteAlert(session: Binding<AnalysisSession?>) -> some View {
        modifier(SessionDeleteAlertModifier(session: session))
    }
}

/// Trends charts without its own NavigationStack (embedded in LogView).
private struct TrendsContent: View {
    @EnvironmentObject var store: PainStore
    @State private var range: PainStore.TrendRange = .threeMonths
    @AppStorage("trends_include_aged") private var includeAged = false
    @AppStorage("trends_include_low_confidence") private var includeLowConfidence = false

    private var filter: PainStore.TrendFilter {
        PainStore.TrendFilter(includeAged: includeAged, includeLowConfidence: includeLowConfidence)
    }

    private var hasAnySuccess: Bool {
        store.sessions.contains(where: \.faceFound)
    }

    private var hiddenCount: Int {
        store.sessions.filter { $0.faceFound && !filter.admits($0) }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !hasAnySuccess {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No trend data yet")
                            .font(.headline)
                        Text("Successful Action Units captures will plot estimated PSPI over time here.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .animatedCard()
                    .transition(AppAnimations.cardTransition)
                } else {
                    RangePicker(range: $range)
                        .staggeredAppear(index: 0)
                    filterCard
                        .staggeredAppear(index: 1)
                    TrendChart(range: range, filter: filter)
                        .staggeredAppear(index: 2)
                        .transition(AppAnimations.cardTransition)
                    TrendStats(range: range, filter: filter)
                        .staggeredAppear(index: 3)
                        .transition(AppAnimations.cardTransition)
                }
            }
            .padding()
        }
        .animation(AppAnimations.smooth, value: hasAnySuccess)
        .animation(AppAnimations.chart, value: range)
        .animation(AppAnimations.chart, value: filter)
    }

    private var filterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Include low-confidence captures", isOn: $includeLowConfidence)
            Toggle("Include aged captures", isOn: $includeAged)
            Text(
                hiddenCount == 0
                    ? "Showing every successful capture."
                    : "\(hiddenCount) \(hiddenCount == 1 ? "capture" : "captures") hidden. Aged photos aren’t your real face, and low-confidence ones are noisier."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding()
        .animatedCard()
    }
}

#Preview {
    LogView()
        .environmentObject(PainStore())
}
