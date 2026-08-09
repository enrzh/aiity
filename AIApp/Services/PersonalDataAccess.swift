import Foundation
#if canImport(EventKit)
import EventKit
#endif

// MARK: - Vocabulary

/// The two personal-data domains the agent can touch. Files are deliberately
/// NOT in here: they have no system authorization at all, only the documents
/// the user handed over in this session (`UserFileAccess`).
enum PersonalDataDomain: String, CaseIterable {
    case reminders
    case calendar
}

/// What this app may currently do with a domain — the app's own vocabulary so
/// every decision can be tested without EventKit, a device, or a TCC prompt.
///
/// `writeOnly` is a real, distinct state (iOS 17 `EKAuthorizationStatus`):
/// the app may add an event and cannot read a single one back. It is the level
/// this app asks for by default, because "put it in my calendar" needs nothing
/// more, and because a permission that cannot read cannot leak.
enum PersonalDataAccess: String, Equatable {
    case notDetermined
    case denied
    /// Blocked by policy (Screen Time / MDM). The user cannot grant it here.
    case restricted
    case writeOnly
    case full

    /// May the app add new items?
    var canWrite: Bool { self == .writeOnly || self == .full }
    /// May the app read existing items? Only full access ever allows this.
    var canRead: Bool { self == .full }
    /// Is a system dialog still possible, or is Settings the only route left?
    var canStillPrompt: Bool { self == .notDetermined }
}

/// Which level to ask for. Least privilege first: `write` is the default for
/// the calendar, `full` is opt-in and the only thing reminders offer at all
/// (EventKit has no write-only variant for reminders).
enum PersonalDataAccessLevel {
    case write
    case full
}

/// One item, reduced to the fields a tool result actually carries. Everything
/// else EventKit knows — notes, attendees, organizer, URL, recurrence,
/// attachments, alarms — is deliberately absent from the type, so it cannot
/// reach a model prompt by accident later.
struct ReminderItem: Equatable {
    var title: String
    var due: Date?
    var listName: String
    var isCompleted: Bool
}

struct CalendarEventItem: Equatable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarName: String
    /// Included because "wann und wo ist X" is the question users ask; notes
    /// and attendees are not, and never leave the device.
    var location: String?
}

struct ReminderDraft: Equatable {
    var title: String
    var due: Date?
    var listName: String?
}

struct CalendarEventDraft: Equatable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarName: String?
    var location: String?
}

enum PersonalDataError: LocalizedError, Equatable {
    case notAuthorized
    case noList
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return String(localized: "Kein Zugriff erlaubt.")
        case .noList:
            return String(localized: "Keine passende Liste bzw. kein Kalender gefunden.")
        case .saveFailed(let message):
            return message
        }
    }
}

// MARK: - The seam

/// Everything the tools need from EventKit, as a protocol.
///
/// The tools NEVER touch `EKEventStore`. That is what makes the interesting
/// half — the authorization matrix, argument validation, the confirmation
/// gate, the failure latch — testable at all: a simulator cannot be made to
/// answer "denied" on demand, and a unit test must never depend on a TCC
/// prompt that a human has to tap.
protocol PersonalDataStore: AnyObject {
    func access(_ domain: PersonalDataDomain) -> PersonalDataAccess
    /// MUST only ever be called from a foreground user action (a tap in
    /// Settings). Nothing in the tool path calls this.
    func requestAccess(_ domain: PersonalDataDomain, level: PersonalDataAccessLevel) async -> PersonalDataAccess

    func listNames(_ domain: PersonalDataDomain) -> [String]

    func createReminder(_ draft: ReminderDraft) async throws -> ReminderItem
    func reminders(limit: Int, includeCompleted: Bool) async throws -> [ReminderItem]

    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEventItem
    func events(from: Date, to: Date, limit: Int) async throws -> [CalendarEventItem]
}

/// Answers "no" to everything. Used where EventKit does not exist, and as the
/// safe default anywhere a store is structurally required.
final class DeniedPersonalDataStore: PersonalDataStore {
    func access(_ domain: PersonalDataDomain) -> PersonalDataAccess { .denied }
    func requestAccess(_ domain: PersonalDataDomain, level: PersonalDataAccessLevel) async -> PersonalDataAccess { .denied }
    func listNames(_ domain: PersonalDataDomain) -> [String] { [] }
    func createReminder(_ draft: ReminderDraft) async throws -> ReminderItem { throw PersonalDataError.notAuthorized }
    func reminders(limit: Int, includeCompleted: Bool) async throws -> [ReminderItem] { throw PersonalDataError.notAuthorized }
    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEventItem { throw PersonalDataError.notAuthorized }
    func events(from: Date, to: Date, limit: Int) async throws -> [CalendarEventItem] { throw PersonalDataError.notAuthorized }
}

/// The single production instance, resolved once.
enum PersonalData {
    static let store: PersonalDataStore = {
        #if canImport(EventKit)
        return EventKitStore.shared
        #else
        return DeniedPersonalDataStore()
        #endif
    }()
}

// MARK: - Limits

/// The bounds every read is clamped to. A calendar is the most sensitive text
/// on the phone, and a cloud model sees whatever a tool returns — so the caps
/// are hard, live in one place, and are asserted by tests rather than trusted
/// to the model's arguments.
enum PersonalToolLimits {
    static let defaultItemLimit = 10
    static let maxItemLimit = 25
    /// The longest window `list_calendar_events` will read, whatever the model
    /// asks for. "Export my year" is not a thing this tool can do.
    static let maxRangeDays = 31
    /// Longest text `read_user_file` hands to the model.
    static let maxFileCharacters = 20_000
    /// Largest file it will even open.
    static let maxFileBytes = 512 * 1024

    static func clampedLimit(_ requested: Int?) -> Int {
        guard let requested else { return defaultItemLimit }
        return min(max(requested, 1), maxItemLimit)
    }

    /// Clamp a requested window to `maxRangeDays`, keeping the start fixed.
    /// An inverted or empty range collapses to a single day.
    static func clampedRange(from start: Date, to end: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let ceiling = start.addingTimeInterval(Double(maxRangeDays) * 86_400)
        if end <= start {
            return (start, min(start.addingTimeInterval(86_400), ceiling))
        }
        return (start, min(end, ceiling))
    }
}

// MARK: - Availability policy

/// Which tools may be OFFERED to the model right now.
///
/// A tool the model cannot use must not appear in the request at all. The app
/// already learned this the expensive way with `generate_image`: the system
/// prompt advertised it with no image provider configured, so the model
/// promised pictures it could never produce. A denied calendar permission is
/// the same bug with a worse failure mode — the model would announce an
/// appointment that does not exist.
enum PersonalToolPolicy {
    static let createReminder = "create_reminder"
    static let listReminders = "list_reminders"
    static let createEvent = "create_calendar_event"
    static let listEvents = "list_calendar_events"
    static let listFiles = "list_user_files"
    static let readFile = "read_user_file"
    static let writeFile = "write_user_file"

    static let allNames: Set<String> = [
        createReminder, listReminders, createEvent, listEvents,
        listFiles, readFile, writeFile,
    ]

    /// - Parameters:
    ///   - enabled: the user's master switch (Mehr → Agent-Werkzeuge).
    ///   - pickedFileCount: documents the user handed over in THIS session.
    static func availableToolNames(
        enabled: Bool,
        reminders: PersonalDataAccess,
        calendar: PersonalDataAccess,
        pickedFileCount: Int
    ) -> Set<String> {
        guard enabled else { return [] }
        var names: Set<String> = []
        if reminders.canWrite { names.insert(createReminder) }
        if reminders.canRead { names.insert(listReminders) }
        if calendar.canWrite { names.insert(createEvent) }
        if calendar.canRead { names.insert(listEvents) }
        if pickedFileCount > 0 {
            names.formUnion([listFiles, readFile, writeFile])
        }
        return names
    }

    /// The prompt section for exactly the tools that are live this turn. Nil
    /// when there are none — the model is then told nothing at all about
    /// calendars, reminders or files, which is the point.
    static func promptSection(names: Set<String>) -> String? {
        guard !names.isEmpty else { return nil }
        var lines: [String] = []
        if names.contains(createReminder) {
            lines.append("- create_reminder(title, due?, list?) — adds ONE reminder to the user's Reminders app.")
        }
        if names.contains(listReminders) {
            lines.append("- list_reminders(limit?, include_completed?) — reads at most \(PersonalToolLimits.maxItemLimit) reminders.")
        }
        if names.contains(createEvent) {
            lines.append("- create_calendar_event(title, start, end?, all_day?, calendar?, location?) — adds ONE event.")
        }
        if names.contains(listEvents) {
            lines.append("- list_calendar_events(start, end, limit?) — reads events in a window of at most \(PersonalToolLimits.maxRangeDays) days.")
        }
        if names.contains(readFile) {
            lines.append("- list_user_files() / read_user_file(name) / write_user_file(name, content) — ONLY the documents the user picked in this session. There is no other file access.")
        }
        return """
        You can act on the user's own device data with these tools:
        \(lines.joined(separator: "\n"))
        Rules, without exception:
        - Dates are absolute and local: "2026-08-12 09:00" or full ISO-8601. Never send a relative phrase ("morgen") — resolve it yourself first, and state the date you used in your answer.
        - Every WRITE shows the user a confirmation sheet with the exact content first. A tool result saying the user declined is final: do NOT retry it, do NOT rephrase it, do NOT call another tool to work around it — say the user cancelled.
        - Never claim you created or read something unless a tool result said so.
        - Read as little as you need: one bounded query, then answer.
        """
    }
}

// MARK: - Date arguments

/// Parsing dates out of model-written JSON.
///
/// Models emit dates in a small set of shapes and one of them is a lie:
/// a bare "morgen"/"tomorrow" that the tool would have to guess at. That one is
/// rejected rather than guessed — a wrong date on a real calendar entry is a
/// missed appointment, and the model is explicitly told to resolve relative
/// dates itself.
enum PersonalToolDates {
    static func parse(
        _ raw: String?,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> Date? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // "12/08/2026" is December 8th to half the world and August 12th to the
        // other half, and `DateFormatter` cheerfully accepts it against a
        // dotted pattern — a six-month error on a real appointment. ISO-8601
        // has no slashes, so refusing them costs nothing and the model is told
        // to send an unambiguous shape.
        guard !text.contains("/") else { return nil }
        text = text.replacingOccurrences(of: "Z", with: "+0000")

        // ISO-8601 with an explicit offset — take it at face value.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw ?? "") { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw ?? "") { return date }

        // Local shapes, interpreted in the user's own time zone.
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH", "dd.MM.yyyy HH:mm", "yyyy-MM-dd", "dd.MM.yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.calendar = calendar
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Stable, unambiguous rendering for a tool result. Local time, with the
    /// zone spelled out so the model cannot silently shift it.
    static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// Human rendering for the CONFIRMATION sheet — this one is read by a
    /// person, so it follows their locale.
    static func display(_ date: Date, allDay: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = allDay ? .none : .short
        return formatter.string(from: date)
    }
}

// MARK: - EventKit

#if canImport(EventKit)
/// The one place `EKEventStore` is touched.
///
/// Creating the store does not prompt; only `requestAccess` does, and that is
/// called from exactly one place: the row the user taps in
/// Mehr → Agent-Werkzeuge. Nothing on the tool path, and nothing reachable
/// from `BackgroundWork`, can reach it.
final class EventKitStore: PersonalDataStore {
    static let shared = EventKitStore()

    private let store = EKEventStore()

    private func entity(_ domain: PersonalDataDomain) -> EKEntityType {
        domain == .reminders ? .reminder : .event
    }

    static func map(_ status: EKAuthorizationStatus) -> PersonalDataAccess {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .full
        case .writeOnly: return .writeOnly
        case .authorized: return .full        // pre-17 spelling of fullAccess
        @unknown default: return .denied
        }
    }

    func access(_ domain: PersonalDataDomain) -> PersonalDataAccess {
        Self.map(EKEventStore.authorizationStatus(for: entity(domain)))
    }

    func requestAccess(_ domain: PersonalDataDomain, level: PersonalDataAccessLevel) async -> PersonalDataAccess {
        switch (domain, level) {
        case (.reminders, _):
            // EventKit has no write-only variant for reminders: full access is
            // the only thing that exists, so that is what the UI says.
            _ = try? await store.requestFullAccessToReminders()
        case (.calendar, .write):
            _ = try? await store.requestWriteOnlyAccessToEvents()
        case (.calendar, .full):
            _ = try? await store.requestFullAccessToEvents()
        }
        return access(domain)
    }

    func listNames(_ domain: PersonalDataDomain) -> [String] {
        // Write-only access returns an empty list here — by design. The tool
        // then falls back to the system default list/calendar.
        guard access(domain).canRead else { return [] }
        return store.calendars(for: entity(domain)).map(\.title)
    }

    // MARK: Reminders

    func createReminder(_ draft: ReminderDraft) async throws -> ReminderItem {
        guard access(.reminders).canWrite else { throw PersonalDataError.notAuthorized }
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        let lists = store.calendars(for: .reminder)
        let target = draft.listName.flatMap { name in
            lists.first { $0.title.compare(name, options: .caseInsensitive) == .orderedSame }
        } ?? store.defaultCalendarForNewReminders()
        guard let list = target else { throw PersonalDataError.noList }
        reminder.calendar = list
        if let due = draft.due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
            // An alarm is what makes a due date actually remind anybody.
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw PersonalDataError.saveFailed(error.localizedDescription)
        }
        return ReminderItem(title: draft.title, due: draft.due, listName: list.title, isCompleted: false)
    }

    func reminders(limit: Int, includeCompleted: Bool) async throws -> [ReminderItem] {
        guard access(.reminders).canRead else { throw PersonalDataError.notAuthorized }
        let predicate = includeCompleted
            ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        return fetched.prefix(limit).map { reminder in
            ReminderItem(
                title: reminder.title ?? "",
                due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                listName: reminder.calendar?.title ?? "",
                isCompleted: reminder.isCompleted
            )
        }
    }

    // MARK: Calendar

    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEventItem {
        guard access(.calendar).canWrite else { throw PersonalDataError.notAuthorized }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.location = draft.location
        let calendars = store.calendars(for: .event)
        let target = draft.calendarName.flatMap { name in
            calendars.first { $0.title.compare(name, options: .caseInsensitive) == .orderedSame }
        } ?? store.defaultCalendarForNewEvents
        guard let calendar = target else { throw PersonalDataError.noList }
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw PersonalDataError.saveFailed(error.localizedDescription)
        }
        return CalendarEventItem(
            title: draft.title, start: draft.start, end: draft.end,
            isAllDay: draft.isAllDay, calendarName: calendar.title, location: draft.location
        )
    }

    func events(from: Date, to: Date, limit: Int) async throws -> [CalendarEventItem] {
        guard access(.calendar).canRead else { throw PersonalDataError.notAuthorized }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { event in
                CalendarEventItem(
                    title: event.title ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarName: event.calendar?.title ?? "",
                    location: event.location
                )
            }
    }
}
#endif
