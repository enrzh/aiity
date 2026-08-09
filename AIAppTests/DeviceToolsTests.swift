import XCTest
@testable import AIApp

// MARK: - Seams

/// Stands in for EventKit. Records every write so a test can assert the one
/// thing that matters most: that a write did NOT happen.
final class StubPersonalDataStore: PersonalDataStore {
    var remindersAccess: PersonalDataAccess = .full
    var calendarAccess: PersonalDataAccess = .full

    private(set) var createdReminders: [ReminderDraft] = []
    private(set) var createdEvents: [CalendarEventDraft] = []
    private(set) var reminderReads = 0
    private(set) var eventReads: [(from: Date, to: Date, limit: Int)] = []
    private(set) var requestedAccess: [(PersonalDataDomain, PersonalDataAccessLevel)] = []

    var reminderResults: [ReminderItem] = []
    var eventResults: [CalendarEventItem] = []
    var failWrites = false

    func access(_ domain: PersonalDataDomain) -> PersonalDataAccess {
        domain == .reminders ? remindersAccess : calendarAccess
    }

    func requestAccess(_ domain: PersonalDataDomain, level: PersonalDataAccessLevel) async -> PersonalDataAccess {
        requestedAccess.append((domain, level))
        return access(domain)
    }

    func listNames(_ domain: PersonalDataDomain) -> [String] { [] }

    func createReminder(_ draft: ReminderDraft) async throws -> ReminderItem {
        if failWrites { throw PersonalDataError.saveFailed("nope") }
        createdReminders.append(draft)
        return ReminderItem(title: draft.title, due: draft.due, listName: draft.listName ?? "Erinnerungen", isCompleted: false)
    }

    func reminders(limit: Int, includeCompleted: Bool) async throws -> [ReminderItem] {
        reminderReads += 1
        return Array(reminderResults.prefix(limit))
    }

    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEventItem {
        if failWrites { throw PersonalDataError.saveFailed("nope") }
        createdEvents.append(draft)
        return CalendarEventItem(
            title: draft.title, start: draft.start, end: draft.end, isAllDay: draft.isAllDay,
            calendarName: draft.calendarName ?? "Privat", location: draft.location
        )
    }

    func events(from: Date, to: Date, limit: Int) async throws -> [CalendarEventItem] {
        eventReads.append((from, to, limit))
        return Array(eventResults.prefix(limit))
    }
}

final class StubConfirmer: ToolConfirming {
    var answer = true
    private(set) var requests: [ToolConfirmationRequest] = []

    init(answer: Bool = true) { self.answer = answer }

    func confirm(_ request: ToolConfirmationRequest) async -> Bool {
        requests.append(request)
        return answer
    }
}

final class StubUserFiles: UserFileProviding {
    var files: [String: String] = [:]
    private(set) var writes: [(name: String, content: String)] = []

    func fileNames() async -> [String] { files.keys.sorted() }

    func read(named name: String) async throws -> String {
        guard let text = files[name] else { throw UserFileAccess.FileError.unknownName(name) }
        return text
    }

    func write(_ text: String, named name: String) async throws {
        guard files[name] != nil else { throw UserFileAccess.FileError.unknownName(name) }
        writes.append((name, text))
        files[name] = text
    }
}

private func runTool(_ tool: AgentTool, _ arguments: [String: Any]) async -> ToolRunResult {
    let data = try! JSONSerialization.data(withJSONObject: arguments)
    return await tool.run(argumentsJSON: String(decoding: data, as: UTF8.self))
}

// MARK: - Authorization → availability

/// A tool the model cannot use must not be offered. This is the same bug class
/// `generate_image` had (advertised with no provider configured); on a calendar
/// it would mean the model announcing appointments that were never created.
final class DeviceToolAvailabilityTests: XCTestCase {

    private func names(
        enabled: Bool = true,
        reminders: PersonalDataAccess = .notDetermined,
        calendar: PersonalDataAccess = .notDetermined,
        files: Int = 0
    ) -> Set<String> {
        PersonalToolPolicy.availableToolNames(
            enabled: enabled, reminders: reminders, calendar: calendar, pickedFileCount: files
        )
    }

    func testNothingIsOfferedBeforeThePermissionExists() {
        XCTAssertTrue(names().isEmpty)
        XCTAssertTrue(names(reminders: .denied, calendar: .denied).isEmpty)
        XCTAssertTrue(names(reminders: .restricted, calendar: .restricted).isEmpty)
    }

    /// Write-only calendar access is the default the app asks for, and it must
    /// offer exactly one tool: you cannot read what you may only write.
    func testWriteOnlyCalendarOffersCreateAndNeverRead() {
        XCTAssertEqual(names(calendar: .writeOnly), [PersonalToolPolicy.createEvent])
    }

    func testFullAccessOffersBothHalves() {
        XCTAssertEqual(
            names(reminders: .full, calendar: .full),
            [PersonalToolPolicy.createReminder, PersonalToolPolicy.listReminders,
             PersonalToolPolicy.createEvent, PersonalToolPolicy.listEvents]
        )
    }

    /// Reminders have no write-only level in EventKit at all — if one ever
    /// appears, it must behave like the calendar's.
    func testWriteOnlyRemindersWouldStillOnlyCreate() {
        XCTAssertEqual(names(reminders: .writeOnly), [PersonalToolPolicy.createReminder])
    }

    func testFileToolsExistOnlyWhileTheUserHasSharedSomething() {
        XCTAssertTrue(names(files: 0).isEmpty)
        XCTAssertEqual(
            names(files: 1),
            [PersonalToolPolicy.listFiles, PersonalToolPolicy.readFile, PersonalToolPolicy.writeFile]
        )
    }

    /// The master switch beats every granted permission.
    func testTheMasterSwitchWithholdsEverything() {
        XCTAssertTrue(names(enabled: false, reminders: .full, calendar: .full, files: 3).isEmpty)
    }

    /// The registry must build exactly the tools the policy allows — not one
    /// more. A tool built "just in case" is a tool the model will find.
    func testTheRegistryBuildsExactlyTheAllowedTools() {
        let store = StubPersonalDataStore()
        store.remindersAccess = .notDetermined
        store.calendarAccess = .writeOnly
        let allowed = names(calendar: .writeOnly, files: 2)
        let tools = ToolRegistry.personalTools(
            names: allowed, store: store, files: StubUserFiles(), confirmer: StubConfirmer()
        )
        XCTAssertEqual(Set(tools.map { $0.spec.name }), allowed)
    }

    func testTheRegistryBuildsNothingWhenNothingIsAllowed() {
        let tools = ToolRegistry.personalTools(
            names: [], store: StubPersonalDataStore(), files: StubUserFiles(), confirmer: StubConfirmer()
        )
        XCTAssertTrue(tools.isEmpty)
    }

    /// The prompt may only describe tools that are actually in the request.
    func testThePromptSectionMentionsOnlyTheLiveTools() throws {
        XCTAssertNil(PersonalToolPolicy.promptSection(names: []))
        let section = try XCTUnwrap(PersonalToolPolicy.promptSection(names: [PersonalToolPolicy.createEvent]))
        XCTAssertTrue(section.contains("create_calendar_event"))
        XCTAssertFalse(section.contains("list_calendar_events"))
        XCTAssertFalse(section.contains("create_reminder"))
        XCTAssertFalse(section.contains("read_user_file"))
    }

    func testASystemPromptWithoutDeviceToolsNeverMentionsThem() {
        var settings = ProviderSettings()
        settings.presetId = "openai"
        let without = ChatSession.buildSystemPrompt(settings: settings, editing: nil, userText: "hi")
        XCTAssertFalse(without.contains("create_calendar_event"))
        XCTAssertFalse(without.contains("create_reminder"))

        let with = ChatSession.buildSystemPrompt(
            settings: settings, editing: nil, userText: "hi",
            deviceToolNames: [PersonalToolPolicy.createReminder]
        )
        XCTAssertTrue(with.contains("create_reminder"))
        XCTAssertFalse(with.contains("list_reminders"))
    }

    #if canImport(EventKit)
    /// The one place the OS vocabulary is translated into ours. `authorized`
    /// is the pre-iOS-17 spelling of full access and must not read as denied.
    func testEventKitStatusMapping() {
        XCTAssertEqual(EventKitStore.map(.notDetermined), .notDetermined)
        XCTAssertEqual(EventKitStore.map(.denied), .denied)
        XCTAssertEqual(EventKitStore.map(.restricted), .restricted)
        XCTAssertEqual(EventKitStore.map(.writeOnly), .writeOnly)
        XCTAssertEqual(EventKitStore.map(.fullAccess), .full)
    }
    #endif
}

// MARK: - Arguments

final class DeviceToolArgumentTests: XCTestCase {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d
        components.hour = h; components.minute = min; components.timeZone = berlin
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    func testLocalDateShapesParseInTheUsersTimeZone() {
        XCTAssertEqual(PersonalToolDates.parse("2026-08-12 09:30", timeZone: berlin), date(2026, 8, 12, 9, 30))
        XCTAssertEqual(PersonalToolDates.parse("2026-08-12T09:30", timeZone: berlin), date(2026, 8, 12, 9, 30))
        XCTAssertEqual(PersonalToolDates.parse("12.08.2026 09:30", timeZone: berlin), date(2026, 8, 12, 9, 30))
        XCTAssertEqual(PersonalToolDates.parse("2026-08-12", timeZone: berlin), date(2026, 8, 12))
    }

    func testAnExplicitOffsetWins() {
        // 09:30Z is 11:30 in Berlin summer time — the offset must be honored.
        XCTAssertEqual(PersonalToolDates.parse("2026-08-12T09:30:00Z", timeZone: berlin), date(2026, 8, 12, 11, 30))
    }

    /// A relative phrase is REJECTED, not guessed. Guessing wrong here means a
    /// real appointment on the wrong day.
    func testRelativePhrasesAndJunkAreRejected() {
        for raw in ["morgen", "tomorrow", "next friday", "bald", "", "   ", "12/08/2026"] {
            XCTAssertNil(PersonalToolDates.parse(raw, timeZone: berlin), raw)
        }
        XCTAssertNil(PersonalToolDates.parse(nil))
    }

    func testLimitsAreClamped() {
        XCTAssertEqual(PersonalToolLimits.clampedLimit(nil), PersonalToolLimits.defaultItemLimit)
        XCTAssertEqual(PersonalToolLimits.clampedLimit(0), 1)
        XCTAssertEqual(PersonalToolLimits.clampedLimit(-5), 1)
        XCTAssertEqual(PersonalToolLimits.clampedLimit(5), 5)
        XCTAssertEqual(PersonalToolLimits.clampedLimit(10_000), PersonalToolLimits.maxItemLimit)
    }

    func testTheReadWindowCannotExceedTheCap() {
        let start = date(2026, 1, 1)
        let year = PersonalToolLimits.clampedRange(from: start, to: date(2026, 12, 31))
        XCTAssertEqual(year.start, start)
        XCTAssertEqual(
            year.end.timeIntervalSince(start),
            Double(PersonalToolLimits.maxRangeDays) * 86_400,
            accuracy: 1
        )
        // An inverted range is one day, not a negative one.
        let inverted = PersonalToolLimits.clampedRange(from: start, to: date(2025, 1, 1))
        XCTAssertEqual(inverted.end, start.addingTimeInterval(86_400))
        // A sane range is untouched.
        let week = PersonalToolLimits.clampedRange(from: start, to: date(2026, 1, 8))
        XCTAssertEqual(week.end, date(2026, 1, 8))
    }

    func testNumberAndBooleanArgumentsSurviveEveryEncoding() {
        XCTAssertEqual(intArgument(7), 7)
        XCTAssertEqual(intArgument("7"), 7)
        XCTAssertEqual(intArgument(NSNumber(value: 7)), 7)
        XCTAssertNil(intArgument("sieben"))
        XCTAssertEqual(boolArgument(true), true)
        XCTAssertEqual(boolArgument("false"), false)
        XCTAssertEqual(boolArgument("ja"), true)
        XCTAssertNil(boolArgument("vielleicht"))
    }
}

// MARK: - The confirmation gate

/// The safety property of the whole feature, stated as tests: no confirmation,
/// no write. Not "usually", not "unless the model insists" — never.
final class DeviceToolConfirmationTests: XCTestCase {

    func testADeclinedReminderIsNeverSaved() async {
        let store = StubPersonalDataStore()
        let confirmer = StubConfirmer(answer: false)
        let tool = CreateReminderTool(store: store, confirmer: confirmer, latch: ToolAttemptLatch())

        let result = await runTool(tool, ["title": "Zahnarzt", "due": "2026-08-12 09:00"])

        XCTAssertTrue(store.createdReminders.isEmpty, "a declined confirmation still wrote to the store")
        XCTAssertEqual(confirmer.requests.count, 1)
        XCTAssertTrue(result.text.contains("abgelehnt"))
    }

    func testADeclinedEventIsNeverSaved() async {
        let store = StubPersonalDataStore()
        let confirmer = StubConfirmer(answer: false)
        let tool = CreateCalendarEventTool(store: store, confirmer: confirmer, latch: ToolAttemptLatch())

        _ = await runTool(tool, ["title": "Standup", "start": "2026-08-12 09:00"])

        XCTAssertTrue(store.createdEvents.isEmpty)
    }

    func testADeclinedFileWriteLeavesTheFileAlone() async {
        let files = StubUserFiles()
        files.files = ["notizen.txt": "alt"]
        let confirmer = StubConfirmer(answer: false)
        let tool = WriteUserFileTool(files: files, confirmer: confirmer, latch: ToolAttemptLatch())

        _ = await runTool(tool, ["name": "notizen.txt", "content": "neu"])

        XCTAssertTrue(files.writes.isEmpty)
        XCTAssertEqual(files.files["notizen.txt"], "alt")
    }

    /// The sheet has to show the PAYLOAD, not a category. A user who is only
    /// told "der Agent möchte etwas eintragen" cannot meaningfully consent.
    func testTheSheetShowsTheConcreteContent() async {
        let store = StubPersonalDataStore()
        let confirmer = StubConfirmer(answer: true)
        let tool = CreateCalendarEventTool(store: store, confirmer: confirmer, latch: ToolAttemptLatch())

        _ = await runTool(tool, [
            "title": "Zahnarzt", "start": "2026-08-12 09:00", "end": "2026-08-12 10:00",
            "location": "Hauptstraße 1", "calendar": "Privat",
        ])

        let request = confirmer.requests.first
        XCTAssertNotNil(request)
        XCTAssertTrue(request!.message.contains("Zahnarzt"))
        XCTAssertTrue(request!.message.contains("Hauptstraße 1"))
        XCTAssertTrue(request!.message.contains("Privat"))
        XCTAssertEqual(store.createdEvents.count, 1)
    }

    /// Overwriting a document is destructive and must be labelled as such.
    func testTheFileOverwriteSheetIsMarkedDestructive() async {
        let files = StubUserFiles()
        files.files = ["a.txt": "alt"]
        let confirmer = StubConfirmer(answer: true)
        let tool = WriteUserFileTool(files: files, confirmer: confirmer, latch: ToolAttemptLatch())

        _ = await runTool(tool, ["name": "a.txt", "content": "neu"])

        XCTAssertEqual(confirmer.requests.first?.isDestructive, true)
        XCTAssertEqual(files.files["a.txt"], "neu")
    }

    /// Reads never ask — but they also never write, and they are bounded.
    func testReadsDoNotShowASheet() async {
        let store = StubPersonalDataStore()
        store.eventResults = [CalendarEventItem(
            title: "Standup", start: .now, end: .now.addingTimeInterval(1800),
            isAllDay: false, calendarName: "Arbeit", location: nil
        )]
        let confirmer = StubConfirmer()
        let tool = ListCalendarEventsTool(store: store, latch: ToolAttemptLatch())

        _ = await runTool(tool, ["start": "2026-08-12", "end": "2026-08-13"])

        XCTAssertTrue(confirmer.requests.isEmpty)
        XCTAssertEqual(store.eventReads.count, 1)
    }

    /// A confirmer that cannot present anything must deny, not assume.
    func testTheFallbackConfirmerDeniesEverything() async {
        let denied = await DenyingToolConfirmer().confirm(
            ToolConfirmationRequest(title: "x", lines: [], confirmTitle: "ok")
        )
        XCTAssertFalse(denied)
    }
}

// MARK: - Permission re-check and the failure latch

final class DeviceToolLatchTests: XCTestCase {

    /// Availability is decided when tools are built; authorization can be
    /// revoked in iOS Settings a second later. The tool re-checks and refuses.
    func testARevokedPermissionStopsTheWriteAtCallTime() async {
        let store = StubPersonalDataStore()
        store.calendarAccess = .denied
        let confirmer = StubConfirmer(answer: true)
        let tool = CreateCalendarEventTool(store: store, confirmer: confirmer, latch: ToolAttemptLatch())

        let result = await runTool(tool, ["title": "X", "start": "2026-08-12 09:00"])

        XCTAssertTrue(store.createdEvents.isEmpty)
        XCTAssertTrue(confirmer.requests.isEmpty, "never ask the user to confirm something that cannot happen")
        XCTAssertNotNil(result.userNotice)
    }

    func testARevokedPermissionStopsTheReadAtCallTime() async {
        let store = StubPersonalDataStore()
        store.remindersAccess = .writeOnly     // may write, may not read
        let tool = ListRemindersTool(store: store, latch: ToolAttemptLatch())

        _ = await runTool(tool, [:])

        XCTAssertEqual(store.reminderReads, 0)
    }

    /// One "no" is an answer. The second call is refused without a second
    /// modal alert — the failure mode this latch exists to prevent is a model
    /// that pops the same dialog until the user gives in.
    func testADeclinedConfirmationExhaustsTheToolForTheTurn() async {
        let store = StubPersonalDataStore()
        let confirmer = StubConfirmer(answer: false)
        let latch = ToolAttemptLatch()
        let tool = CreateReminderTool(store: store, confirmer: confirmer, latch: latch)

        _ = await runTool(tool, ["title": "A"])
        let second = await runTool(tool, ["title": "A"])

        XCTAssertEqual(confirmer.requests.count, 1, "the user was asked twice after saying no")
        XCTAssertTrue(second.text.contains(PersonalToolPolicy.createReminder))
        XCTAssertTrue(store.createdReminders.isEmpty)
    }

    func testRepeatedHardFailuresExhaustTheTool() async {
        let store = StubPersonalDataStore()
        store.failWrites = true
        let confirmer = StubConfirmer(answer: true)
        let latch = ToolAttemptLatch()
        let tool = CreateReminderTool(store: store, confirmer: confirmer, latch: latch)

        _ = await runTool(tool, ["title": "A"])
        _ = await runTool(tool, ["title": "A"])
        XCTAssertTrue(latch.isExhausted(PersonalToolPolicy.createReminder))
        let third = await runTool(tool, ["title": "A"])
        XCTAssertEqual(confirmer.requests.count, 2, "an exhausted tool still opened a dialog")
        XCTAssertTrue(third.text.contains("nicht mehr verfügbar"))
    }

    /// The latch is shared per turn, but each tool has its own budget: a
    /// declined calendar write must not silently disable the file tools.
    func testTheBudgetIsPerToolNotGlobal() {
        let latch = ToolAttemptLatch()
        latch.exhaust(PersonalToolPolicy.createEvent)
        XCTAssertTrue(latch.isExhausted(PersonalToolPolicy.createEvent))
        XCTAssertFalse(latch.isExhausted(PersonalToolPolicy.createReminder))
    }

    /// Bad arguments cost a strike but do not kill the tool outright — the
    /// model deserves exactly one chance to fix a date it mistyped.
    func testAnUnparseableDateIsReportedAndRetryable() async {
        let store = StubPersonalDataStore()
        let latch = ToolAttemptLatch()
        let tool = CreateCalendarEventTool(store: store, confirmer: StubConfirmer(), latch: latch)

        let result = await runTool(tool, ["title": "X", "start": "morgen früh"])

        XCTAssertTrue(result.text.hasPrefix("Error:"))
        XCTAssertTrue(store.createdEvents.isEmpty)
        XCTAssertFalse(latch.isExhausted(PersonalToolPolicy.createEvent))
    }
}

// MARK: - Bounds actually applied by the tools

final class DeviceToolBoundsTests: XCTestCase {

    func testTheEventToolClampsWhateverTheModelAsksFor() async {
        let store = StubPersonalDataStore()
        let tool = ListCalendarEventsTool(store: store, latch: ToolAttemptLatch())

        _ = await runTool(tool, ["start": "2026-01-01", "end": "2027-01-01", "limit": 500])

        let query = store.eventReads.first
        XCTAssertNotNil(query)
        XCTAssertEqual(query!.limit, PersonalToolLimits.maxItemLimit)
        XCTAssertEqual(
            query!.to.timeIntervalSince(query!.from),
            Double(PersonalToolLimits.maxRangeDays) * 86_400,
            accuracy: 1
        )
    }

    func testAnEventWithoutAnEndGetsOneHourAndNeverANegativeSpan() async {
        let store = StubPersonalDataStore()
        let tool = CreateCalendarEventTool(store: store, confirmer: StubConfirmer(), latch: ToolAttemptLatch())

        _ = await runTool(tool, ["title": "A", "start": "2026-08-12 09:00"])
        _ = await runTool(tool, ["title": "B", "start": "2026-08-12 09:00", "end": "2026-08-12 08:00"])

        XCTAssertEqual(store.createdEvents.count, 2)
        for event in store.createdEvents {
            XCTAssertEqual(event.end.timeIntervalSince(event.start), 3600, accuracy: 1)
        }
    }

    /// What a read hands to the model — and therefore to the configured cloud
    /// provider — is exactly these fields. Nothing here may grow silently.
    func testAReadResultCarriesOnlyTheDocumentedFields() async {
        let store = StubPersonalDataStore()
        let start = Date(timeIntervalSince1970: 1_786_000_000)
        store.eventResults = [CalendarEventItem(
            title: "Zahnarzt", start: start, end: start.addingTimeInterval(3600),
            isAllDay: false, calendarName: "Privat", location: "Hauptstraße 1"
        )]
        let tool = ListCalendarEventsTool(store: store, latch: ToolAttemptLatch())

        let result = await runTool(tool, ["start": "2026-08-01", "end": "2026-08-02"])

        XCTAssertTrue(result.text.contains("Zahnarzt"))
        XCTAssertTrue(result.text.contains("Privat"))
        XCTAssertTrue(result.text.contains("Hauptstraße 1"))
        XCTAssertNil(result.userNotice)
        // The item type has no notes/attendees to leak in the first place.
        XCTAssertFalse(result.text.lowercased().contains("attendee"))
    }

    func testAnEmptyReadSaysSoInsteadOfInventing() async {
        let store = StubPersonalDataStore()
        let tool = ListRemindersTool(store: store, latch: ToolAttemptLatch())
        let result = await runTool(tool, [:])
        XCTAssertTrue(result.text.contains("Keine"))
    }
}

// MARK: - Files

final class UserFileToolTests: XCTestCase {

    func testAFileTheUserNeverPickedCannotBeWrittenAndNeverAsks() async {
        let files = StubUserFiles()
        files.files = ["erlaubt.txt": "x"]
        let confirmer = StubConfirmer(answer: true)
        let tool = WriteUserFileTool(files: files, confirmer: confirmer, latch: ToolAttemptLatch())

        let result = await runTool(tool, ["name": "/etc/passwd", "content": "boom"])

        XCTAssertTrue(files.writes.isEmpty)
        XCTAssertTrue(confirmer.requests.isEmpty, "an unpickable file must not even produce a dialog")
        XCTAssertTrue(result.text.contains("nicht freigegeben"))
    }

    func testAFileTheUserNeverPickedCannotBeRead() async {
        let files = StubUserFiles()
        files.files = ["erlaubt.txt": "x"]
        let tool = ReadUserFileTool(files: files, latch: ToolAttemptLatch())

        let result = await runTool(tool, ["name": "../../Library/Preferences/com.aiity.app.plist"])

        XCTAssertFalse(result.text.contains("x\n"))
        XCTAssertTrue(result.text.contains("konnte nicht gelesen werden"))
    }

    func testListingShowsOnlyWhatWasShared() async {
        let files = StubUserFiles()
        files.files = ["b.txt": "", "a.txt": ""]
        let listed = await runTool(ListUserFilesTool(files: files), [:])
        XCTAssertTrue(listed.text.contains("a.txt"))
        XCTAssertTrue(listed.text.contains("b.txt"))

        let empty = await runTool(ListUserFilesTool(files: StubUserFiles()), [:])
        XCTAssertTrue(empty.text.contains("keine Dateien"))
    }

    /// The real security-scoped path: pick → read → write → revoke. On the
    /// simulator a temp URL is not actually sandbox-scoped, so this pins the
    /// bookmark round trip and the lifecycle, not the sandbox itself.
    @MainActor
    func testBookmarkLifecycleFromPickToRevoke() throws {
        let access = UserFileAccess.shared
        access.removeAll()
        defer { access.removeAll() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiity-test-\(UUID().uuidString).txt")
        try "hallo".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(access.add(url), .added(url.lastPathComponent))
        XCTAssertEqual(access.add(url), .duplicate(url.lastPathComponent), "the same file must not stack up")
        XCTAssertEqual(access.names, [url.lastPathComponent])

        XCTAssertEqual(try access.readText(named: url.lastPathComponent), "hallo")
        try access.writeText("neu", named: url.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "neu")

        // Case-insensitive by name, but only for names that are in the table.
        XCTAssertThrowsError(try access.readText(named: "irgendwas.txt"))

        access.remove(access.entries[0].id)
        XCTAssertTrue(access.entries.isEmpty)
        XCTAssertThrowsError(try access.readText(named: url.lastPathComponent)) { error in
            XCTAssertEqual(error as? UserFileAccess.FileError, .unknownName(url.lastPathComponent))
        }
    }

    @MainActor
    func testALargeFileIsRefusedRatherThanTruncatedIntoAPrompt() throws {
        let access = UserFileAccess.shared
        access.removeAll()
        defer { access.removeAll() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiity-big-\(UUID().uuidString).txt")
        try String(repeating: "x", count: PersonalToolLimits.maxFileBytes + 10)
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = access.add(url)
        XCTAssertThrowsError(try access.readText(named: url.lastPathComponent))
    }

    @MainActor
    func testTheSharedSetIsBounded() throws {
        let access = UserFileAccess.shared
        access.removeAll()
        defer { access.removeAll() }

        var urls: [URL] = []
        for index in 0...UserFileAccess.maxEntries {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("aiity-many-\(index)-\(UUID().uuidString).txt")
            try "x".write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let results = urls.map { access.add($0) }
        XCTAssertEqual(access.entries.count, UserFileAccess.maxEntries)
        if case .failed = results.last {} else {
            XCTFail("the \(UserFileAccess.maxEntries + 1)th file was accepted")
        }
    }
}

// MARK: - Reachability

/// Nothing added here may be reachable from a background task. The permission
/// dialog is a foreground-only affordance, and a write the user cannot see is
/// exactly what this feature must never do. Source-level because that is where
/// the guarantee lives — there is no runtime path to assert the absence of.
final class DeviceToolReachabilityTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testBackgroundWorkNeverTouchesPersonalData() throws {
        let text = try source("AIApp/Services/BackgroundWork.swift")
        for forbidden in ["EventKit", "PersonalData", "UserFileAccess", "ToolRegistry", "AgentTool"] {
            XCTAssertFalse(text.contains(forbidden), "BackgroundWork must not reach \(forbidden)")
        }
    }

    /// EventKit permission is requested in exactly ONE file — the settings
    /// screen's store call. If a second call site appears, this fails.
    func testAccessIsRequestedOnlyFromTheSettingsScreen() throws {
        for file in ["AIApp/Tools/PersonalDataTools.swift", "AIApp/Tools/UserFileTools.swift", "AIApp/Agent/AgentLoop.swift", "AIApp/Tools/AgentTool.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("requestAccess("), "\(file) must not request a permission")
            XCTAssertFalse(text.contains("requestFullAccess"), "\(file) must not request a permission")
        }
    }

    /// The mini-app JS bridge is a sandbox boundary. These tools are agent
    /// tools only — no bridge action may name them.
    func testTheMiniAppBridgeGetsNoneOfThis() throws {
        let text = try source("AIApp/Views/MiniAppRunnerView.swift")
        for forbidden in ["EventKit", "PersonalData", "UserFileAccess", "create_reminder", "create_calendar_event"] {
            XCTAssertFalse(text.contains(forbidden), "the mini-app bridge must not expose \(forbidden)")
        }
    }
}
