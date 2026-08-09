import Foundation

// MARK: - Shared helpers

/// Number arguments arrive as Int, Double or String depending on the provider
/// and the model's mood. All three mean the same thing.
func intArgument(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
    return nil
}

func boolArgument(_ value: Any?) -> Bool? {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? String {
        switch string.lowercased() {
        case "true", "yes", "1", "ja": return true
        case "false", "no", "0", "nein": return false
        default: return nil
        }
    }
    return nil
}

func stringArgument(_ value: Any?) -> String? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        return nil
    }
    return text
}

/// Every device-data tool answers failures the same way: the German cause for
/// the user, plus an explicit "do not call me again this turn" for the model.
/// Without the second half a refused permission becomes a loop of modal
/// alerts, which is the worst possible way to say no.
enum PersonalToolReply {
    static func declined(_ tool: String) -> ToolRunResult {
        ToolRunResult(
            String(localized: "Der Nutzer hat das abgelehnt. Es wurde nichts gespeichert. Sag ihm genau das und rufe \(tool) in diesem Zug nicht erneut auf.")
        )
    }

    static func blocked(_ message: String, tool: String, notify: Bool = true) -> ToolRunResult {
        ToolRunResult(
            message + " " + String(localized: "Sag dem Nutzer genau das und rufe \(tool) in diesem Zug nicht erneut auf."),
            userNotice: notify ? message : nil
        )
    }

    static func exhausted(_ tool: String) -> ToolRunResult {
        ToolRunResult(String(localized: "\(tool) ist in diesem Zug nicht mehr verfügbar (mehrfach fehlgeschlagen oder abgelehnt). Antworte ohne dieses Werkzeug."))
    }

    static func badArgument(_ message: String) -> ToolRunResult {
        ToolRunResult("Error: " + message)
    }
}

// MARK: - create_reminder

/// Adds ONE reminder, after the user has seen exactly what it says and tapped
/// "Eintragen". There is no bulk variant and no update/delete counterpart —
/// see `PersonalDataTools` for why.
struct CreateReminderTool: AgentTool {
    let store: PersonalDataStore
    let confirmer: ToolConfirming
    let latch: ToolAttemptLatch

    static let name = PersonalToolPolicy.createReminder

    var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description: "Create a single reminder in the user's Reminders app. The user must confirm a sheet showing the exact content before anything is saved.",
            parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "What the reminder says"],
                    "due": ["type": "string", "description": "Optional absolute local due date/time, 'YYYY-MM-DD HH:mm' or ISO-8601. Never a relative phrase."],
                    "list": ["type": "string", "description": "Optional name of an existing reminder list. Default list if omitted."],
                ],
                "required": ["title"],
            ]
        )
    }

    func run(argumentsJSON: String) async -> ToolRunResult {
        guard !latch.isExhausted(Self.name) else { return PersonalToolReply.exhausted(Self.name) }
        let args = toolArguments(argumentsJSON)
        guard let title = stringArgument(args["title"]) else {
            latch.record(Self.name)
            return PersonalToolReply.badArgument("title is required")
        }
        // Re-checked at call time, not only at offer time: the user can revoke
        // access in iOS Settings while the app sits in the background.
        guard store.access(.reminders).canWrite else {
            latch.exhaust(Self.name)
            return PersonalToolReply.blocked(
                String(localized: "Kein Zugriff auf Erinnerungen — unter Mehr → Agent-Werkzeuge erlauben."),
                tool: Self.name
            )
        }
        var due: Date?
        if let raw = stringArgument(args["due"]) {
            guard let parsed = PersonalToolDates.parse(raw) else {
                latch.record(Self.name)
                return PersonalToolReply.badArgument("could not parse due date „\(raw)“ — use YYYY-MM-DD HH:mm")
            }
            due = parsed
        }
        let listName = stringArgument(args["list"])

        var lines = [String(localized: "Titel: \(title)")]
        if let due { lines.append(String(localized: "Fällig: \(PersonalToolDates.display(due))")) }
        lines.append(String(localized: "Liste: \(listName ?? String(localized: "Standardliste"))"))
        let confirmed = await confirmer.confirm(ToolConfirmationRequest(
            title: String(localized: "Erinnerung anlegen?"),
            lines: lines,
            confirmTitle: String(localized: "Anlegen")
        ))
        guard confirmed else {
            latch.exhaust(Self.name)
            return PersonalToolReply.declined(Self.name)
        }

        do {
            let item = try await store.createReminder(
                ReminderDraft(title: title, due: due, listName: listName)
            )
            var summary = String(localized: "Erinnerung „\(item.title)“ in Liste „\(item.listName)“ angelegt.")
            if let due = item.due { summary += " " + String(localized: "Fällig \(PersonalToolDates.format(due)).") }
            return ToolRunResult(summary)
        } catch {
            latch.record(Self.name)
            return PersonalToolReply.blocked(
                String(localized: "Erinnerung konnte nicht gespeichert werden: \(error.localizedDescription)"),
                tool: Self.name
            )
        }
    }
}

// MARK: - list_reminders

/// Bounded read. Returns title, due date, list and done-flag — nothing else,
/// because nothing else is needed to answer "was steht noch an?".
struct ListRemindersTool: AgentTool {
    let store: PersonalDataStore
    let latch: ToolAttemptLatch

    static let name = PersonalToolPolicy.listReminders

    var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description: "Read the user's reminders (title, due date, list). Returns at most \(PersonalToolLimits.maxItemLimit) items. Call once, then answer.",
            parameters: [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "How many items, 1–\(PersonalToolLimits.maxItemLimit). Default \(PersonalToolLimits.defaultItemLimit)."],
                    "include_completed": ["type": "boolean", "description": "Include already completed reminders. Default false."],
                ],
                "required": [],
            ]
        )
    }

    func run(argumentsJSON: String) async -> ToolRunResult {
        guard !latch.isExhausted(Self.name) else { return PersonalToolReply.exhausted(Self.name) }
        guard store.access(.reminders).canRead else {
            latch.exhaust(Self.name)
            return PersonalToolReply.blocked(
                String(localized: "Kein Lesezugriff auf Erinnerungen — unter Mehr → Agent-Werkzeuge erlauben."),
                tool: Self.name
            )
        }
        let args = toolArguments(argumentsJSON)
        let limit = PersonalToolLimits.clampedLimit(intArgument(args["limit"]))
        let includeCompleted = boolArgument(args["include_completed"]) ?? false
        do {
            let items = try await store.reminders(limit: limit, includeCompleted: includeCompleted)
            guard !items.isEmpty else { return ToolRunResult(String(localized: "Keine offenen Erinnerungen.")) }
            let body = items.map { item -> String in
                var line = "- \(item.title)"
                if let due = item.due { line += " (fällig \(PersonalToolDates.format(due)))" }
                line += " [\(item.listName)]"
                if item.isCompleted { line += " ✓" }
                return line
            }.joined(separator: "\n")
            return ToolRunResult("\(items.count)/\(limit):\n\(body)")
        } catch {
            latch.record(Self.name)
            return PersonalToolReply.blocked(
                String(localized: "Erinnerungen konnten nicht gelesen werden: \(error.localizedDescription)"),
                tool: Self.name
            )
        }
    }
}

// MARK: - create_calendar_event

struct CreateCalendarEventTool: AgentTool {
    let store: PersonalDataStore
    let confirmer: ToolConfirming
    let latch: ToolAttemptLatch

    static let name = PersonalToolPolicy.createEvent
    /// Length of an event whose `end` the model left out.
    static let defaultDuration: TimeInterval = 3600

    var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description: "Create a single calendar event. The user must confirm a sheet showing title, time and calendar before anything is saved.",
            parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Event title"],
                    "start": ["type": "string", "description": "Absolute local start, 'YYYY-MM-DD HH:mm' or ISO-8601. Never a relative phrase."],
                    "end": ["type": "string", "description": "Optional end. Defaults to one hour after start."],
                    "all_day": ["type": "boolean", "description": "Optional all-day event. Default false."],
                    "calendar": ["type": "string", "description": "Optional calendar name. Default calendar if omitted."],
                    "location": ["type": "string", "description": "Optional location"],
                ],
                "required": ["title", "start"],
            ]
        )
    }

    func run(argumentsJSON: String) async -> ToolRunResult {
        guard !latch.isExhausted(Self.name) else { return PersonalToolReply.exhausted(Self.name) }
        let args = toolArguments(argumentsJSON)
        guard let title = stringArgument(args["title"]) else {
            latch.record(Self.name)
            return PersonalToolReply.badArgument("title is required")
        }
        guard let rawStart = stringArgument(args["start"]) else {
            latch.record(Self.name)
            return PersonalToolReply.badArgument("start is required")
        }
        guard let start = PersonalToolDates.parse(rawStart) else {
            latch.record(Self.name)
            return PersonalToolReply.badArgument("could not parse start „\(rawStart)“ — use YYYY-MM-DD HH:mm")
        }
        guard store.access(.calendar).canWrite else {
            latch.exhaust(Self.name)
            return PersonalToolReply.blocked(
                String(localized: "Kein Zugriff auf den Kalender — unter Mehr → Agent-Werkzeuge erlauben."),
                tool: Self.name
            )
        }
        let allDay = boolArgument(args["all_day"]) ?? false
        var end = stringArgument(args["end"]).flatMap { PersonalToolDates.parse($0) }
            ?? start.addingTimeInterval(Self.defaultDuration)
        // An end before the start is a model slip, not a user intent; a saved
        // event with a negative duration is unfixable weirdness in Kalender.
        if end <= start { end = start.addingTimeInterval(Self.defaultDuration) }
        let calendarName = stringArgument(args["calendar"])
        let location = stringArgument(args["location"])

        var lines = [String(localized: "Titel: \(title)")]
        if allDay {
            lines.append(String(localized: "Wann: \(PersonalToolDates.display(start, allDay: true)) (ganztägig)"))
        } else {
            lines.append(String(localized: "Von: \(PersonalToolDates.display(start))"))
            lines.append(String(localized: "Bis: \(PersonalToolDates.display(end))"))
        }
        if let location { lines.append(String(localized: "Ort: \(location)")) }
        lines.append(String(localized: "Kalender: \(calendarName ?? String(localized: "Standardkalender"))"))
        let confirmed = await confirmer.confirm(ToolConfirmationRequest(
            title: String(localized: "Termin eintragen?"),
            lines: lines,
            confirmTitle: String(localized: "Eintragen")
        ))
        guard confirmed else {
            latch.exhaust(Self.name)
            return PersonalToolReply.declined(Self.name)
        }

        do {
            let item = try await store.createEvent(CalendarEventDraft(
                title: title, start: start, end: end, isAllDay: allDay,
                calendarName: calendarName, location: location
            ))
            return ToolRunResult(String(localized: "Termin „\(item.title)“ am \(PersonalToolDates.format(item.start)) im Kalender „\(item.calendarName)“ eingetragen."))
        } catch {
            latch.record(Self.name)
            return PersonalToolReply.blocked(
                String(localized: "Termin konnte nicht eingetragen werden: \(error.localizedDescription)"),
                tool: Self.name
            )
        }
    }
}

// MARK: - list_calendar_events

/// The most privacy-sensitive read in the app: whatever this returns is sent
/// to whichever provider the user configured. Hence the hard window
/// (`maxRangeDays`), the hard item cap, and a result shape that carries title,
/// time, calendar and location — and never notes, attendees or organizers.
struct ListCalendarEventsTool: AgentTool {
    let store: PersonalDataStore
    let latch: ToolAttemptLatch

    static let name = PersonalToolPolicy.listEvents

    var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description: "Read calendar events in a date range (title, start, end, calendar, location). The range is capped at \(PersonalToolLimits.maxRangeDays) days and \(PersonalToolLimits.maxItemLimit) events. Call once with the narrowest range that answers the question.",
            parameters: [
                "type": "object",
                "properties": [
                    "start": ["type": "string", "description": "Window start, 'YYYY-MM-DD' or 'YYYY-MM-DD HH:mm'"],
                    "end": ["type": "string", "description": "Window end. At most \(PersonalToolLimits.maxRangeDays) days after start."],
                    "limit": ["type": "integer", "description": "How many events, 1–\(PersonalToolLimits.maxItemLimit). Default \(PersonalToolLimits.defaultItemLimit)."],
                ],
                "required": ["start", "end"],
            ]
        )
    }

    func run(argumentsJSON: String) async -> ToolRunResult {
        guard !latch.isExhausted(Self.name) else { return PersonalToolReply.exhausted(Self.name) }
        guard store.access(.calendar).canRead else {
            latch.exhaust(Self.name)
            return PersonalToolReply.blocked(
                String(localized: "Kein Lesezugriff auf den Kalender — unter Mehr → Agent-Werkzeuge erlauben."),
                tool: Self.name
            )
        }
        let args = toolArguments(argumentsJSON)
        guard let rawStart = stringArgument(args["start"]), let start = PersonalToolDates.parse(rawStart) else {
            latch.record(Self.name)
            return PersonalToolReply.badArgument("start is required, format YYYY-MM-DD")
        }
        guard let rawEnd = stringArgument(args["end"]), let requestedEnd = PersonalToolDates.parse(rawEnd) else {
            latch.record(Self.name)
            return PersonalToolReply.badArgument("end is required, format YYYY-MM-DD")
        }
        let window = PersonalToolLimits.clampedRange(from: start, to: requestedEnd)
        let limit = PersonalToolLimits.clampedLimit(intArgument(args["limit"]))
        do {
            let items = try await store.events(from: window.start, to: window.end, limit: limit)
            let header = "\(PersonalToolDates.format(window.start)) – \(PersonalToolDates.format(window.end))"
            guard !items.isEmpty else {
                return ToolRunResult(String(localized: "Keine Termine im Zeitraum \(header)."))
            }
            let body = items.map { item -> String in
                var line = "- \(item.title): "
                line += item.isAllDay
                    ? "\(PersonalToolDates.format(item.start)) (ganztägig)"
                    : "\(PersonalToolDates.format(item.start)) – \(PersonalToolDates.format(item.end))"
                line += " [\(item.calendarName)]"
                if let location = item.location, !location.isEmpty { line += " @ \(location)" }
                return line
            }.joined(separator: "\n")
            return ToolRunResult("\(header) (\(items.count)):\n\(body)")
        } catch {
            latch.record(Self.name)
            return PersonalToolReply.blocked(
                String(localized: "Kalender konnte nicht gelesen werden: \(error.localizedDescription)"),
                tool: Self.name
            )
        }
    }
}
