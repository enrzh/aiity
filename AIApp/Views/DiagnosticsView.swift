import SwiftUI
import UIKit

/// "Warum ist die App abgestürzt?" — answered inside the app, exportable in one
/// tap. The whole point is that nobody has to go digging in iOS Settings →
/// Analyse & Verbesserungen → Analysedaten, or attach the phone to a Mac.
struct DiagnosticsView: View {
    @State private var run: DiagnosticRun?
    @State private var verdict: DiagnosticVerdict = .noPreviousRun
    @State private var metricKit: String?
    @State private var exportURL: URL?
    @State private var copied = false
    @State private var showClearConfirm = false

    var body: some View {
        List {
            verdictSection

            if let run {
                factsSection(run)

                if case .crashed(let fatal) = verdict {
                    crashSection(fatal)
                }
                if case .diedUnexpectedly = verdict {
                    causesSection(run)
                }

                breadcrumbSection(run)
            }

            metricKitSection
            exportSection
        }
        .navigationTitle("Diagnose")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .confirmationDialog(
            String(localized: "Diagnose löschen?"), isPresented: $showClearConfirm, titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                DiagnosticsRecorder.shared.clear()
                load()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der gespeicherte Bericht des letzten Laufs wird entfernt. Der aktuelle Lauf wird weiter aufgezeichnet.")
        }
    }

    // MARK: Sections

    private var verdictSection: some View {
        Section {
            HStack(alignment: .top, spacing: Theme.space2) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(DiagnosticsReport.headline(verdict, run: run))
                        .font(.headline)
                        .foregroundStyle(tint)
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("diagnostics-verdict")
        } header: {
            Text("Letzter Lauf")
        }
    }

    private func factsSection(_ run: DiagnosticRun) -> some View {
        Section("Fakten") {
            LabeledContent("Start", value: DiagnosticsReport.stamp(run.startedAt))
            LabeledContent("Laufzeit", value: DiagnosticsReport.duration(
                from: run.startedAt,
                to: run.fatal?.at ?? run.endedCleanlyAt ?? run.lastActiveAt
            ))
            LabeledContent("Zustand", value: run.wasInBackground ? "Hintergrund" : "Vordergrund")
            LabeledContent("Version", value: "\(run.appVersion) (\(run.build))")
            LabeledContent("System", value: "iOS \(run.systemVersion) · \(run.deviceModel)")
            if !run.provider.isEmpty {
                LabeledContent("Anbieter", value: run.model.isEmpty
                               ? run.provider
                               : "\(run.provider) · \(run.model)")
            }
            LabeledContent("Speicher", value: String(
                format: "%.0f MB · %d Warnung(en)", run.footprintMB, run.memoryWarnings
            ))
        }
    }

    private func crashSection(_ fatal: DiagnosticFatal) -> some View {
        Section {
            LabeledContent("Art", value: fatal.kind == .exception ? "Ausnahme" : "Signal")
            LabeledContent("Name", value: fatal.name)
            if !fatal.reason.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bedeutung").font(.caption).foregroundStyle(.secondary)
                    Text(fatal.reason).font(.subheadline)
                }
            }
            if !fatal.frames.isEmpty {
                DisclosureGroup("Stack (\(fatal.frames.count) Frames)") {
                    ForEach(Array(fatal.frames.prefix(40).enumerated()), id: \.offset) { _, frame in
                        Text(frame)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Absturz")
        } footer: {
            if fatal.kind == .signal {
                Text("Die Adressen sind nicht symbolisiert — ein Signal-Handler darf nichts allozieren. Der Systembericht unten liefert dieselben Frames mit Namen, sobald iOS ihn ausliefert.")
            }
        }
    }

    private func causesSection(_ run: DiagnosticRun) -> some View {
        Section {
            ForEach(Array(DiagnosticsReport.unexpectedCauses(run).enumerated()), id: \.offset) { _, cause in
                Label {
                    Text(cause).font(.subheadline)
                } icon: {
                    Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Mögliche Ursachen")
        } footer: {
            Text("Nach dem Ende lässt sich das von innen nicht sicher unterscheiden. Die Liste ist nach dem geordnet, was die Fakten oben hergeben — sie ist keine Diagnose.")
        }
    }

    private func breadcrumbSection(_ run: DiagnosticRun) -> some View {
        Section("Ereignisse davor") {
            if run.breadcrumbs.isEmpty {
                Text("Keine aufgezeichnet").foregroundStyle(.secondary)
            } else {
                ForEach(Array(run.breadcrumbs.suffix(40).enumerated().reversed()), id: \.offset) { _, crumb in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(crumb.message)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(DiagnosticsReport.time(crumb.at)) · \(crumb.category)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private var metricKitSection: some View {
        Section {
            if let metricKit, !metricKit.isEmpty {
                ForEach(Array(DiagnosticsReport.metricKitHighlights(metricKit).enumerated()), id: \.offset) { _, line in
                    Text(line.trimmingCharacters(in: .whitespaces))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else {
                Text("Noch keiner. iOS liefert seinen eigenen Absturzbericht erst beim übernächsten Start an die App aus.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Systembericht (MetricKit)")
        } footer: {
            Text("Von iOS erstellt, mit symbolisiertem Stack und Abbruchgrund — genauer als alles, was die App selbst mitschreiben kann. Kommt direkt in der App an, ohne Umweg über die Einstellungen.")
        }
    }

    private var exportSection: some View {
        Section {
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Bericht teilen", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("share-diagnostics")
            }

            Button {
                UIPasteboard.general.string = DiagnosticsRecorder.shared.renderReport()
                copied = true
            } label: {
                Label(copied ? "Kopiert" : "Vollen Bericht kopieren",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityIdentifier("copy-diagnostics")

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("Diagnose löschen", systemImage: "trash")
            }
        } header: {
            Text("Export")
        } footer: {
            Text("Der Bericht enthält Gerätemodell, iOS-Version, App-Version, Anbietername und die Ereignisliste. Keine Nachrichteninhalte, keine API-Schlüssel.")
        }
    }

    // MARK: Appearance

    private var icon: String {
        switch verdict {
        case .clean: return "checkmark.circle.fill"
        case .crashed: return "exclamationmark.octagon.fill"
        case .diedUnexpectedly: return "questionmark.circle.fill"
        case .noPreviousRun: return "clock"
        }
    }

    private var tint: Color {
        switch verdict {
        case .clean: return .green
        case .crashed: return .red
        case .diedUnexpectedly: return .orange
        case .noPreviousRun: return .secondary
        }
    }

    private var explanation: String {
        switch verdict {
        case .clean:
            return String(localized: "Die App wurde regulär beendet oder in den Hintergrund geschickt.")
        case .crashed(let fatal):
            return fatal.reason.isEmpty
                ? "Der Absturz wurde in der App abgefangen."
                : fatal.reason
        case .diedUnexpectedly:
            return String(localized: "Der Prozess endete, ohne dass die App es mitbekommen hat. Die Ursachen unten sind nach Plausibilität geordnet.")
        case .noPreviousRun:
            return String(localized: "Es liegt noch kein früherer Lauf vor.")
        }
    }

    private func load() {
        let snapshot = DiagnosticsRecorder.shared.lastRunSnapshot()
        run = snapshot.run
        verdict = snapshot.verdict
        metricKit = snapshot.metricKit
        exportURL = DiagnosticsRecorder.shared.exportReport()
        copied = false
    }
}
