import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(MetricKit)
import MetricKit
#endif

// MARK: - Stored shapes
//
// Every type here is written by one build and read by the NEXT one — that is
// the whole point, the crash happens before the update and the report is read
// after it. So each decoder is hand-written with `decodeIfPresent`: Swift's
// synthesized decoder treats a DEFAULTED property as REQUIRED, and adding one
// field to a stored type has already, once in this project, made every stored
// record undecodable. A diagnostics file that stops decoding the moment the
// app changes is worse than none, because it fails silently exactly when a
// report is wanted.

/// One thing that happened, cheap enough to record on every notable action.
struct DiagnosticBreadcrumb: Codable, Sendable {
    var at: Date
    var category: String
    var message: String

    init(at: Date = Date(), category: String, message: String) {
        self.at = at
        self.category = category
        self.message = message
    }

    private enum CodingKeys: String, CodingKey { case at, category, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date(timeIntervalSince1970: 0)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "?"
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

/// What killed the process, when we managed to catch it in-process.
struct DiagnosticFatal: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, Equatable { case exception, signal }

    var kind: Kind
    var at: Date
    /// `NSInvalidArgumentException`, or `SIGSEGV`.
    var name: String
    var reason: String
    /// Unsymbolicated return addresses — see `DiagnosticsReport` for why.
    var frames: [String]

    init(kind: Kind, at: Date, name: String, reason: String, frames: [String]) {
        self.kind = kind
        self.at = at
        self.name = name
        self.reason = reason
        self.frames = frames
    }

    private enum CodingKeys: String, CodingKey { case kind, at, name, reason, frames }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .kind) ?? "signal"
        kind = Kind(rawValue: raw) ?? .signal
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date(timeIntervalSince1970: 0)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "unbekannt"
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        frames = try c.decodeIfPresent([String].self, forKey: .frames) ?? []
    }
}

/// One launch-to-death of the process.
struct DiagnosticRun: Codable, Sendable {
    var id: UUID
    var startedAt: Date
    var appVersion: String
    var build: String
    var systemVersion: String
    var deviceModel: String

    /// Set when the app is backgrounded or terminated in an orderly way. `nil`
    /// on a record recovered at the next launch means the process died without
    /// getting the chance — a crash, a jetsam kill, a watchdog kill, or a
    /// force-quit. Those four are not distinguishable with certainty from
    /// inside the process; `DiagnosticsReport` says so rather than guessing.
    var endedCleanlyAt: Date?
    var lastActiveAt: Date
    var wasInBackground: Bool
    var memoryWarnings: Int
    var footprintMB: Double
    var availableMemoryMB: Double
    var provider: String
    var model: String
    var breadcrumbs: [DiagnosticBreadcrumb]
    var fatal: DiagnosticFatal?

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        appVersion: String,
        build: String,
        systemVersion: String,
        deviceModel: String,
        endedCleanlyAt: Date? = nil,
        lastActiveAt: Date = Date(),
        wasInBackground: Bool = false,
        memoryWarnings: Int = 0,
        footprintMB: Double = 0,
        availableMemoryMB: Double = 0,
        provider: String = "",
        model: String = "",
        breadcrumbs: [DiagnosticBreadcrumb] = [],
        fatal: DiagnosticFatal? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.appVersion = appVersion
        self.build = build
        self.systemVersion = systemVersion
        self.deviceModel = deviceModel
        self.endedCleanlyAt = endedCleanlyAt
        self.lastActiveAt = lastActiveAt
        self.wasInBackground = wasInBackground
        self.memoryWarnings = memoryWarnings
        self.footprintMB = footprintMB
        self.availableMemoryMB = availableMemoryMB
        self.provider = provider
        self.model = model
        self.breadcrumbs = breadcrumbs
        self.fatal = fatal
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, appVersion, build, systemVersion, deviceModel
        case endedCleanlyAt, lastActiveAt, wasInBackground, memoryWarnings
        case footprintMB, availableMemoryMB, provider, model, breadcrumbs, fatal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date(timeIntervalSince1970: 0)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "?"
        build = try c.decodeIfPresent(String.self, forKey: .build) ?? "?"
        systemVersion = try c.decodeIfPresent(String.self, forKey: .systemVersion) ?? "?"
        deviceModel = try c.decodeIfPresent(String.self, forKey: .deviceModel) ?? "?"
        endedCleanlyAt = try c.decodeIfPresent(Date.self, forKey: .endedCleanlyAt)
        lastActiveAt = try c.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? startedAt
        wasInBackground = try c.decodeIfPresent(Bool.self, forKey: .wasInBackground) ?? false
        memoryWarnings = try c.decodeIfPresent(Int.self, forKey: .memoryWarnings) ?? 0
        footprintMB = try c.decodeIfPresent(Double.self, forKey: .footprintMB) ?? 0
        availableMemoryMB = try c.decodeIfPresent(Double.self, forKey: .availableMemoryMB) ?? 0
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        breadcrumbs = try c.decodeIfPresent([DiagnosticBreadcrumb].self, forKey: .breadcrumbs) ?? []
        fatal = try c.decodeIfPresent(DiagnosticFatal.self, forKey: .fatal)
    }
}

/// What we can honestly say about how a run ended.
enum DiagnosticVerdict: Sendable, Equatable {
    /// Backgrounded or terminated in an orderly way.
    case clean
    /// Caught in-process — we know the signal or the exception.
    case crashed(DiagnosticFatal)
    /// Died without reaching a handler. Cause is inferred, not known.
    case diedUnexpectedly
    /// No prior run on record (first launch, or diagnostics were cleared).
    case noPreviousRun
}

// MARK: - Signal trampoline
//
// A signal handler may only call async-signal-safe functions. It may not
// allocate, take a lock, or touch Swift runtime machinery — doing so in a
// process that is already dying usually produces a second, uninformative
// crash on top of the first. So everything this path needs is allocated at
// install time and only `open`/`write`/`close`/`backtrace` run here.

private let signalFrameCapacity = 64
private nonisolated(unsafe) var signalFrameBuffer =
    UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: signalFrameCapacity)
/// Pre-rendered C string; `strdup`ed at install so the handler never allocates.
private nonisolated(unsafe) var signalMarkerPath: UnsafeMutablePointer<CChar>?

private func diagnosticsWrite(_ fd: Int32, _ text: StaticString) {
    text.withUTF8Buffer { buffer in
        guard let base = buffer.baseAddress else { return }
        _ = write(fd, base, buffer.count)
    }
}

private let signalDigitCapacity = 24
/// Allocated once, at install. `[CChar](repeating:count:)` lowers to
/// `swift_allocObject` -> `malloc`, and stack promotion is an optimiser
/// courtesy that does not happen at all at -Onone. Calling malloc from a
/// handler for a SIGABRT that was itself raised from inside malloc — heap
/// corruption and double free being the commonest causes on iOS — deadlocks on
/// the allocator lock, and by then the marker file is already open with
/// O_TRUNC, so the previous run's marker is destroyed and the new one never
/// finished.
private nonisolated(unsafe) var signalDigitBuffer =
    UnsafeMutablePointer<CChar>.allocate(capacity: signalDigitCapacity)

/// Decimal/hex rendering without `snprintf`, which is not signal-safe, and
/// without allocating.
private func diagnosticsWriteNumber(_ fd: Int32, _ value: UInt64, radix: UInt64 = 10) {
    var index = signalDigitCapacity
    var remaining = value
    repeat {
        index -= 1
        let digit = remaining % radix
        signalDigitBuffer[index] = CChar(digit < 10 ? 48 + digit : 87 + digit)
        remaining /= radix
    } while remaining > 0 && index > 0
    _ = write(fd, signalDigitBuffer + index, signalDigitCapacity - index)
}

private func diagnosticsSignalHandler(_ signalNumber: Int32) {
    if let path = signalMarkerPath {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd >= 0 {
            diagnosticsWrite(fd, "sig ")
            diagnosticsWriteNumber(fd, UInt64(max(0, signalNumber)))
            diagnosticsWrite(fd, "\n")

            let count = backtrace(signalFrameBuffer, Int32(signalFrameCapacity))
            for slot in 0..<Int(max(0, count)) {
                guard let frame = signalFrameBuffer[slot] else { continue }
                diagnosticsWrite(fd, "f 0x")
                diagnosticsWriteNumber(fd, UInt64(UInt(bitPattern: frame)), radix: 16)
                diagnosticsWrite(fd, "\n")
            }
            close(fd)
        }
    }
    // Re-raise with the default disposition so the system still writes its own
    // crash report and MetricKit still sees the crash. Swallowing the signal
    // here would trade Apple's symbolicated stack for our unsymbolicated one.
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

// MARK: - Recorder

/// Records what the app was doing, notices when a run does not end cleanly, and
/// keeps the previous run's evidence where the user can export it — without
/// going through iOS Settings or plugging into a Mac.
///
/// Deliberately not `@MainActor`: group rounds, provider calls and tool runs
/// all happen off the main actor and are exactly the things worth recording.
final class DiagnosticsRecorder: @unchecked Sendable {
    static let shared = DiagnosticsRecorder()

    static let maxBreadcrumbs = 150
    /// Disk writes are throttled so a burst of breadcrumbs cannot turn into a
    /// burst of writes. Kept deliberately short: the seconds immediately before
    /// a kill are the most valuable ones in the whole record, and anything not
    /// yet flushed when the process dies is gone. Identity fields
    /// (`noteProvider`, scene phase, memory warnings, a caught fatal) bypass
    /// the throttle entirely rather than risk being the thing that is missing.
    private static let flushInterval: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "de.aiity.diagnostics", qos: .utility)
    private let directory: URL
    private var current: DiagnosticRun
    private var previousRun: DiagnosticRun?
    private var previousMetric: String?
    private var installed = false
    private var lastFlush = Date.distantPast
    private var flushScheduled = false

    private var currentURL: URL { directory.appendingPathComponent("current-run.json") }
    private var previousURL: URL { directory.appendingPathComponent("previous-run.json") }
    private var markerURL: URL { directory.appendingPathComponent("fatal-signal.txt") }
    private var metricURL: URL { directory.appendingPathComponent("metrickit-latest.json") }

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Diagnostics", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        #if DEBUG
        // Stage a prior run so the crash paths can be driven in a UI test
        // without having to actually kill the process mid-test.
        if let seed = ProcessInfo.processInfo.environment["AIITY_DIAGNOSTICS_SEED"] {
            try? Data(seed.utf8).write(to: base.appendingPathComponent("current-run.json"))
        }
        #endif

        let info = Bundle.main.infoDictionary
        self.current = DiagnosticRun(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            systemVersion: DiagnosticsRecorder.systemVersionString(),
            deviceModel: DiagnosticsRecorder.hardwareModel()
        )
        rotate()
    }

    // MARK: Lifecycle

    /// Rotate last run's file into place and fold in anything the signal
    /// handler managed to write. Called once, from `init`.
    private func rotate() {
        let fm = FileManager.default
        let decoder = JSONDecoder()

        var recovered: DiagnosticRun?
        if let data = try? Data(contentsOf: currentURL) {
            recovered = try? decoder.decode(DiagnosticRun.self, from: data)
        }

        // The marker is written by the signal handler of the run that died, so
        // it belongs to `recovered`, not to us.
        if let marker = try? String(contentsOf: markerURL, encoding: .utf8) {
            let died = (try? fm.attributesOfItem(atPath: markerURL.path)[.modificationDate] as? Date) ?? nil
            if let fatal = DiagnosticsRecorder.parseSignalMarker(marker, at: died ?? Date()) {
                if recovered != nil {
                    recovered?.fatal = fatal
                } else {
                    // Marker without a run file: still worth reporting.
                    recovered = DiagnosticRun(
                        startedAt: fatal.at,
                        appVersion: "?", build: "?", systemVersion: "?", deviceModel: "?",
                        fatal: fatal
                    )
                }
            }
            try? fm.removeItem(at: markerURL)
        }

        if let recovered {
            previousRun = recovered
            if let data = try? JSONEncoder().encode(recovered) {
                try? data.write(to: previousURL, options: .atomic)
            }
        } else if let data = try? Data(contentsOf: previousURL) {
            // No run file (e.g. diagnostics installed after a crash) — keep
            // showing the last report we did manage to keep.
            previousRun = try? decoder.decode(DiagnosticRun.self, from: data)
        }

        // The MetricKit payload belongs to ONE crash, but nothing ever removed
        // it: a report four launches later still printed "sauber beendet" for
        // the last run and, immediately below, a system diagnostic from an
        // older crash — asserting a crash that did not happen in the run being
        // examined. Fold it in once, then retire it.
        previousMetric = try? String(contentsOf: metricURL, encoding: .utf8)
        if previousMetric != nil {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            try? fm.moveItem(
                at: metricURL,
                to: directory.appendingPathComponent("metrickit-\(stamp).json")
            )
        }
        try? fm.removeItem(at: currentURL)
    }

    /// Install crash handlers, the MetricKit subscriber, and the Analytics
    /// bridge. Safe to call more than once.
    func install() {
        queue.sync {
            guard !installed else { return }
            installed = true
        }

        signalMarkerPath = strdup(markerURL.path)

        NSSetUncaughtExceptionHandler { exception in
            DiagnosticsRecorder.shared.recordUncaught(exception)
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, diagnosticsSignalHandler)
        }

        // Existing analytics events are already the app's own account of what
        // it is doing — reuse them rather than sprinkling a second set of
        // calls through the codebase.
        let downstream = Analytics.handler
        Analytics.handler = { event, props in
            downstream(event, props)
            let detail = props.isEmpty
                ? event
                : "\(event) " + props.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            DiagnosticsRecorder.shared.record("event", detail)
        }

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil
        ) { _ in
            DiagnosticsRecorder.shared.recordMemoryWarning()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { _ in
            DiagnosticsRecorder.shared.markCleanExit(reason: "terminate")
        }
        #endif

        MetricKitCollector.shared.start(into: metricURL)

        record("app", "Start · \(current.appVersion) (\(current.build)) · iOS \(current.systemVersion)")
        flush(force: true)
    }

    // MARK: Recording

    /// Note something worth seeing in a crash report. Cheap; safe from any thread.
    func record(_ category: String, _ message: String) {
        let crumb = DiagnosticBreadcrumb(category: category, message: message)
        queue.async { [self] in
            current.breadcrumbs.append(crumb)
            if current.breadcrumbs.count > Self.maxBreadcrumbs {
                current.breadcrumbs.removeFirst(current.breadcrumbs.count - Self.maxBreadcrumbs)
            }
            current.lastActiveAt = crumb.at
            scheduleFlushLocked()
        }
    }

    /// Which provider/model a run was using is the first question about any
    /// agent-app crash, so it is a field rather than a breadcrumb.
    func noteProvider(_ provider: String, model: String) {
        queue.async { [self] in
            current.provider = provider
            current.model = model
            // Not throttled: this is set once per send and is the first thing
            // anyone asks about a crash in this app. Losing it to a 0.5s window
            // would cost far more than the write saves.
            flushLocked(force: true)
        }
    }

    func noteScenePhase(background: Bool) {
        queue.async { [self] in
            current.wasInBackground = background
            current.lastActiveAt = Date()
            if background {
                // Backgrounding is the last reliable moment before a jetsam
                // kill, so treat it as a clean end and re-open on foreground.
                current.endedCleanlyAt = Date()
            } else {
                current.endedCleanlyAt = nil
            }
            flushLocked(force: true)
        }
        record("app", background ? "In den Hintergrund" : "Wieder im Vordergrund")
    }

    func markCleanExit(reason: String) {
        queue.sync { [self] in
            current.endedCleanlyAt = Date()
            current.breadcrumbs.append(
                DiagnosticBreadcrumb(category: "app", message: "Beendet (\(reason))")
            )
            flushLocked(force: true)
        }
    }

    private func recordMemoryWarning() {
        queue.async { [self] in
            current.memoryWarnings += 1
            current.footprintMB = DiagnosticsRecorder.footprintMB()
            current.availableMemoryMB = DiagnosticsRecorder.availableMemoryMB()
            current.breadcrumbs.append(DiagnosticBreadcrumb(
                category: "speicher",
                message: String(
                    format: "Speicherwarnung · %.0f MB belegt · %.0f MB frei",
                    current.footprintMB, current.availableMemoryMB
                )
            ))
            flushLocked(force: true)
        }
    }

    /// Uncaught ObjC exception. Unlike a signal this runs before the process
    /// is torn down, so a normal encode is safe here.
    private func recordUncaught(_ exception: NSException) {
        let fatal = DiagnosticFatal(
            kind: .exception,
            at: Date(),
            name: exception.name.rawValue,
            reason: exception.reason ?? "",
            frames: exception.callStackSymbols
        )
        queue.sync { [self] in
            current.fatal = fatal
            current.footprintMB = DiagnosticsRecorder.footprintMB()
            flushLocked(force: true)
        }
    }

    // MARK: Reading

    /// The previous run, its verdict, and the raw MetricKit payload if iOS has
    /// handed one over yet.
    func lastRunSnapshot() -> (run: DiagnosticRun?, verdict: DiagnosticVerdict, metricKit: String?) {
        queue.sync {
            // Re-read rather than trust what `rotate()` saw. MetricKit delivers
            // its payload a moment AFTER launch, so a value cached at init is
            // stale exactly when it matters: the report would claim iOS had
            // sent nothing while its crash diagnostic sat unread on disk. Seen
            // for real on device — the breadcrumb said the payload had arrived
            // and the section above it said there was none.
            // Re-read only a payload that arrived DURING this run — iOS
            // delivers it a moment after launch, so a value cached at init is
            // stale exactly when it matters. `rotate()` has already retired any
            // older file, so whatever is here now belongs to the crash being
            // reported.
            if let fresh = try? String(contentsOf: metricURL, encoding: .utf8), !fresh.isEmpty {
                previousMetric = fresh
            }
            guard let previousRun else { return (nil, .noPreviousRun, previousMetric) }
            return (previousRun, DiagnosticsRecorder.verdict(for: previousRun), previousMetric)
        }
    }

    func currentRunSnapshot() -> DiagnosticRun {
        queue.sync {
            var snapshot = current
            snapshot.footprintMB = DiagnosticsRecorder.footprintMB()
            snapshot.availableMemoryMB = DiagnosticsRecorder.availableMemoryMB()
            return snapshot
        }
    }

    /// Everything, rendered for a human. This is what the export shares.
    func renderReport() -> String {
        let snapshot = lastRunSnapshot()
        return DiagnosticsReport.render(
            previous: snapshot.run,
            verdict: snapshot.verdict,
            metricKit: snapshot.metricKit,
            current: currentRunSnapshot(),
            generatedAt: Date()
        )
    }

    /// Write the report where `ShareLink` can hand it to Mail, Files, AirDrop.
    func exportReport() -> URL? {
        let text = renderReport()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiity-diagnose-\(stamp).txt")
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func clear() {
        queue.sync { [self] in
            previousRun = nil
            previousMetric = nil
            let fm = FileManager.default
            try? fm.removeItem(at: previousURL)
            try? fm.removeItem(at: metricURL)
            try? fm.removeItem(at: markerURL)
        }
    }

    static func verdict(for run: DiagnosticRun) -> DiagnosticVerdict {
        if let fatal = run.fatal { return .crashed(fatal) }
        if run.endedCleanlyAt != nil { return .clean }
        return .diedUnexpectedly
    }

    // MARK: Persistence

    private func scheduleFlushLocked() {
        guard !flushScheduled else { return }
        let elapsed = Date().timeIntervalSince(lastFlush)
        if elapsed >= Self.flushInterval {
            flushLocked(force: true)
            return
        }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + (Self.flushInterval - elapsed)) { [self] in
            flushScheduled = false
            flushLocked(force: true)
        }
    }

    private func flush(force: Bool) {
        queue.async { [self] in flushLocked(force: force) }
    }

    private func flushLocked(force: Bool) {
        guard force || Date().timeIntervalSince(lastFlush) >= Self.flushInterval else { return }
        lastFlush = Date()
        // Sample memory on every write, not only when iOS sends a warning.
        // Otherwise a recovered run reports "0 MB belegt", which reads as
        // evidence AGAINST memory pressure when it is really just an unsampled
        // field — and memory is the one number that decides whether an
        // unexplained death was a jetsam kill.
        current.footprintMB = DiagnosticsRecorder.footprintMB()
        current.availableMemoryMB = DiagnosticsRecorder.availableMemoryMB()
        guard let data = try? JSONEncoder().encode(current) else { return }
        try? data.write(to: currentURL, options: .atomic)
    }

    // MARK: Facts about the machine

    static func parseSignalMarker(_ text: String, at date: Date) -> DiagnosticFatal? {
        var signalNumber: Int32?
        var frames: [String] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("sig ") {
                signalNumber = Int32(line.dropFirst(4).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("f ") {
                frames.append(String(line.dropFirst(2)))
            }
        }
        guard let signalNumber else { return nil }
        return DiagnosticFatal(
            kind: .signal,
            at: date,
            name: signalName(signalNumber),
            reason: signalMeaning(signalNumber),
            frames: frames
        )
    }

    static func signalName(_ number: Int32) -> String {
        switch number {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default: return "Signal \(number)"
        }
    }

    /// Plain-language meaning. `SIGTRAP`/`SIGILL` matter most here: that is what
    /// a Swift runtime trap looks like — a force-unwrapped nil, an out-of-range
    /// index, a failed precondition — which is the likeliest way this app dies.
    static func signalMeaning(_ number: Int32) -> String {
        switch number {
        case SIGABRT:
            return "Abbruch — meist eine nicht abgefangene Ausnahme oder ein fehlgeschlagenes assert."
        case SIGSEGV:
            return String(localized: "Ungültiger Speicherzugriff — Zugriff auf bereits freigegebenen Speicher.")
        case SIGBUS:
            return String(localized: "Nicht ausgerichteter oder ungültiger Speicherzugriff.")
        case SIGILL, SIGTRAP:
            return String(localized: "Swift-Laufzeitfehler — force-unwrap auf nil, Index außerhalb des Bereichs, ")
                + String(localized: "fehlgeschlagene precondition, oder arithmetischer Überlauf.")
        case SIGFPE:
            return String(localized: "Rechenfehler — Division durch null oder Überlauf.")
        default:
            return "Vom System beendet."
        }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    static func availableMemoryMB() -> Double {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        return Double(os_proc_available_memory()) / 1_048_576
        #else
        return 0
        #endif
    }

    static func systemVersionString() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    /// `iPhone17,1` rather than the marketing name — it is what a crash report
    /// carries and what an Apple engineer would ask for.
    static func hardwareModel() -> String {
        // On the simulator `utsname.machine` is the Mac's architecture
        // (`arm64`), which would put a meaningless model in every report
        // produced during development.
        if let simulated = ProcessInfo.processInfo
            .environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return "\(simulated) (Simulator)"
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let scalars = mirror.children.compactMap { child -> String? in
            guard let value = child.value as? Int8, value != 0 else { return nil }
            return String(UnicodeScalar(UInt8(bitPattern: value)))
        }
        let name = scalars.joined()
        return name.isEmpty ? "?" : name
    }
}

// MARK: - MetricKit

/// iOS's own crash diagnostics, delivered straight to the app after the next
/// launch. This is the part that carries a *symbolicated* call stack and, for
/// Swift runtime traps, the actual failure message — the two things an
/// in-process handler cannot get. Nothing here requires the user to open
/// Settings or connect a Mac.
private final class MetricKitCollector: NSObject, @unchecked Sendable {
    static let shared = MetricKitCollector()
    private var destination: URL?

    func start(into url: URL) {
        #if canImport(MetricKit) && !targetEnvironment(simulator)
        destination = url
        MXMetricManager.shared.add(self)
        #endif
    }
}

#if canImport(MetricKit) && !targetEnvironment(simulator)
extension MetricKitCollector: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        // Performance metrics — not what a crash report needs.
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let destination else { return }
        let documents = payloads.map { payload -> String in
            String(decoding: payload.jsonRepresentation(), as: UTF8.self)
        }
        guard !documents.isEmpty else { return }
        let joined = documents.joined(separator: "\n")
        try? Data(joined.utf8).write(to: destination, options: .atomic)
        DiagnosticsRecorder.shared.record(
            "metrickit", "\(payloads.count) Diagnose-Bericht(e) vom System erhalten"
        )
    }
}
#endif
