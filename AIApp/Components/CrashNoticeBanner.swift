import SwiftUI

/// Surfaces the previous run's bad ending once, on the next launch.
///
/// Without this the diagnostics screen is only useful to someone who already
/// suspects a crash and goes looking for it — which is the opposite of the
/// point. Shown once per run id, so a single crash cannot nag across launches.
struct CrashNoticeBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var verdict: DiagnosticVerdict = .noPreviousRun
    @State private var runId: UUID?
    @State private var dismissed = false
    @State private var showReport = false
    @State private var landed = false

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
                        .symbolEffect(.bounce, options: .nonRepeating, value: landed)
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
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // 44pt hit target without 44pt of layout: the negative
                    // padding hands back the extra 8pt per side, so the banner
                    // keeps its height while the frame still catches the touch.
                    .padding(-8)
                    .accessibilityLabel("Hinweis schließen")
                }
                .padding(.horizontal, Theme.space2)
                .padding(.vertical, Theme.space2)
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
                // Reduce Motion: no slide (fade only) and no symbol bounce —
                // same one-shot gate AppEmptyState uses.
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .top).combined(with: .opacity)
                )
                .onAppear {
                    if !reduceMotion { landed = true }
                }
            }
        }
        .animation(
            Theme.Motion.preferSpring(Theme.Motion.soft, reduceMotion: reduceMotion),
            value: shouldShow
        )
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
        case .crashed(let fatal): return String(localized: "Letzter Start endete mit einem Absturz (\(fatal.name))")
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
