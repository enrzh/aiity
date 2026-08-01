import SwiftUI

/// Surfaces the previous run's bad ending once, on the next launch.
///
/// Without this the diagnostics screen is only useful to someone who already
/// suspects a crash and goes looking for it — which is the opposite of the
/// point. Shown once per run id, so a single crash cannot nag across launches.
struct CrashNoticeBanner: View {
    @State private var verdict: DiagnosticVerdict = .noPreviousRun
    @State private var runId: UUID?
    @State private var dismissed = false
    @State private var showReport = false

    private static let seenKey = "diagnostics.lastNoticedRun.v1"

    var body: some View {
        // A real container, not a Group: `Group` forwards modifiers to its
        // children, so `.task` below would never fire while the banner is
        // hidden — and the banner starts hidden, so it could never appear at
        // all. VStack owns the modifier itself and collapses to zero height
        // when there is nothing to show.
        VStack(spacing: 0) {
            if shouldShow {
                HStack(spacing: Theme.space2) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Text("Bericht ansehen oder teilen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Ansehen") { showReport = true }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    Button {
                        markSeen()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hinweis schließen")
                }
                .padding(.horizontal, Theme.space2)
                .padding(.vertical, 10)
                .glassSurface(
                    in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                )
                .padding(.horizontal, Theme.space2)
                // Combined so the banner is ONE element carrying the whole
                // message; without this its parts are exposed separately and
                // the identifier does not surface at all.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("crash-notice")
                .accessibilityLabel(title)
            }
        }
        .task { load() }
        .sheet(isPresented: $showReport) {
            NavigationStack { DiagnosticsView() }
                .presentationDetents([.large])
                .onDisappear { markSeen() }
        }
    }

    private var shouldShow: Bool {
        guard !dismissed else { return false }
        switch verdict {
        case .crashed, .diedUnexpectedly: return true
        case .clean, .noPreviousRun: return false
        }
    }

    private var title: String {
        switch verdict {
        case .crashed(let fatal): return "Letzter Start endete mit einem Absturz (\(fatal.name))"
        default: return "Letzter Start wurde unerwartet beendet"
        }
    }

    private var icon: String {
        if case .crashed = verdict { return "exclamationmark.octagon.fill" }
        return "questionmark.circle.fill"
    }

    private var tint: Color {
        if case .crashed = verdict { return .red }
        return .orange
    }

    private func load() {
        let snapshot = DiagnosticsRecorder.shared.lastRunSnapshot()
        verdict = snapshot.verdict
        runId = snapshot.run?.id
        // A run already reported stays reported — one crash, one notice.
        if let runId, UserDefaults.standard.string(forKey: Self.seenKey) == runId.uuidString {
            dismissed = true
        }
    }

    private func markSeen() {
        if let runId {
            UserDefaults.standard.set(runId.uuidString, forKey: Self.seenKey)
        }
        dismissed = true
    }
}
