import SwiftUI
import UniformTypeIdentifiers

/// Mehr → Agent-Werkzeuge: the ONLY place any of this app's personal-data
/// permissions are ever requested.
///
/// That is the whole point of the screen existing. The agent tools are
/// withheld from the model until the permission exists, which means the model
/// can never trigger the system dialog on its own — a permission prompt is
/// always the direct result of the user tapping a row here, in the foreground,
/// having just read what it is for.
struct AgentToolsSettingsView: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @ObservedObject private var files = UserFileAccess.shared
    @Environment(\.scenePhase) private var scenePhase

    private let store = PersonalData.store

    @State private var remindersAccess: PersonalDataAccess = .notDetermined
    @State private var calendarAccess: PersonalDataAccess = .notDetermined
    @State private var showFileImporter = false
    @State private var fileNotice: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $prefs.deviceToolsEnabled) {
                    Label("Agent darf Gerätedaten nutzen", systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("device-tools-toggle")
            } footer: {
                Text("Aus heißt: der Agent bekommt diese Werkzeuge gar nicht erst angeboten — auch wenn du iOS die Rechte schon gegeben hast. Nichts wird gelöscht.")
            }

            Section {
                AppSettingsRow(
                    title: String(localized: "Erinnerungen"),
                    subtitle: Self.statusText(remindersAccess),
                    systemImage: "checklist"
                )
                if remindersAccess.canStillPrompt {
                    Button("Erinnerungen erlauben") {
                        Task { remindersAccess = await store.requestAccess(.reminders, level: .full) }
                    }
                    .accessibilityIdentifier("allow-reminders")
                } else if remindersAccess == .denied {
                    Button("In den iOS-Einstellungen ändern") { Self.openSystemSettings() }
                }
            } header: {
                Text("Erinnerungen")
            } footer: {
                // Honest about the API: EventKit has no write-only mode for
                // reminders, so "nur eintragen" is not on the menu.
                Text("Der Agent kann Erinnerungen anlegen — immer erst, nachdem du den konkreten Eintrag bestätigt hast — und offene Erinnerungen lesen (höchstens \(PersonalToolLimits.maxItemLimit) auf einmal). iOS kennt für Erinnerungen keinen Nur-Schreiben-Zugriff; deshalb ist es Vollzugriff oder gar nichts.")
            }

            Section {
                AppSettingsRow(
                    title: String(localized: "Kalender"),
                    subtitle: Self.statusText(calendarAccess),
                    systemImage: "calendar"
                )
                if calendarAccess.canStillPrompt {
                    Button("Nur eintragen erlauben") {
                        Task { calendarAccess = await store.requestAccess(.calendar, level: .write) }
                    }
                    .accessibilityIdentifier("allow-calendar-write")
                }
                if calendarAccess == .notDetermined || calendarAccess == .writeOnly {
                    Button("Eintragen und lesen erlauben") {
                        Task { calendarAccess = await store.requestAccess(.calendar, level: .full) }
                    }
                    .accessibilityIdentifier("allow-calendar-full")
                }
                if calendarAccess == .denied {
                    Button("In den iOS-Einstellungen ändern") { Self.openSystemSettings() }
                }
            } header: {
                Text("Kalender")
            } footer: {
                Text("„Nur eintragen“ ist die sparsamste Variante: der Agent kann Termine anlegen — nach deiner Bestätigung —, aber keinen einzigen bestehenden Termin sehen. Erst „eintragen und lesen“ erlaubt Fragen wie „was habe ich am Freitag?“. Gelesen werden dann Titel, Zeit, Kalendername und Ort von höchstens \(PersonalToolLimits.maxItemLimit) Terminen aus höchstens \(PersonalToolLimits.maxRangeDays) Tagen — und diese Angaben gehen an den KI-Anbieter, den du eingerichtet hast.")
            }

            Section {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Dateien freigeben", systemImage: "doc.badge.plus")
                }
                .accessibilityIdentifier("share-files")

                ForEach(files.entries) { entry in
                    HStack {
                        Label(entry.name, systemImage: "doc")
                            .lineLimit(1)
                        Spacer()
                        Button {
                            files.remove(entry.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Freigabe entfernen")
                    }
                }
                if !files.entries.isEmpty {
                    Button("Alle Freigaben aufheben", role: .destructive) { files.removeAll() }
                }
                if let fileNotice {
                    Text(fileNotice).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Dateien")
            } footer: {
                Text("Der Agent sieht ausschließlich die Dateien, die du hier auswählst — nichts sonst auf dem Gerät. Die Freigabe gilt nur für diese Sitzung und ist nach dem nächsten App-Start wieder weg. Überschreiben geht nur nach ausdrücklicher Bestätigung.")
            }
        }
        .navigationTitle("Agent-Werkzeuge")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
        .onChange(of: scenePhase) { _, phase in
            // The user may have revoked access in iOS Settings while away.
            if phase == .active { refresh() }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.plainText, .json, .commaSeparatedText, .xml, .yaml, .rtf, .utf8PlainText, .sourceCode, .text],
            allowsMultipleSelection: true
        ) { outcome in
            switch outcome {
            case .success(let urls):
                var added = 0
                var problems: [String] = []
                for url in urls {
                    switch files.add(url) {
                    case .added: added += 1
                    case .duplicate(let name): problems.append(String(localized: "\(name) war schon freigegeben"))
                    case .failed(let message): problems.append(message)
                    }
                }
                fileNotice = problems.isEmpty
                    ? String(localized: "\(added) Datei(en) freigegeben.")
                    : problems.joined(separator: "\n")
            case .failure(let error):
                fileNotice = error.localizedDescription
            }
        }
    }

    private func refresh() {
        remindersAccess = store.access(.reminders)
        calendarAccess = store.access(.calendar)
    }

    static func statusText(_ access: PersonalDataAccess) -> String {
        switch access {
        case .notDetermined: return String(localized: "Nicht erlaubt")
        case .denied: return String(localized: "Abgelehnt — in den iOS-Einstellungen änderbar")
        case .restricted: return String(localized: "Gesperrt (Bildschirmzeit oder Geräteverwaltung)")
        case .writeOnly: return String(localized: "Nur eintragen")
        case .full: return String(localized: "Eintragen und lesen")
        }
    }

    private static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
