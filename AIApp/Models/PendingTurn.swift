import Foundation

/// A turn that was in flight when the app lost its background grant (or was
/// killed). Enough to *replay* the turn — never to resume a half-finished
/// stream, which no provider supports.
struct PendingTurn: Codable, Equatable {
    /// The conversation the turn belongs to. Keyed by id on purpose: the user
    /// may have opened a different chat since, and replaying into whatever is
    /// on screen would put the answer in the wrong conversation.
    var threadId: UUID
    /// The user message that started the turn — what a resume re-sends.
    var userText: String
    /// Where the turn begins in the thread's message array. A resume rewinds
    /// to exactly here.
    var turnStartIndex: Int
    /// Validate→repair passes already spent, so a resume does not hand the
    /// user a fresh budget for a turn that already burned one.
    var repairPasses: Int
    var startedAt: Date
    var updatedAt: Date
    /// Whatever had streamed in when the checkpoint was written. Kept for
    /// diagnostics and for showing the user what they nearly had; the replay
    /// itself discards it (see `ChatSession.rewindToInterruptedTurnStart`).
    var partialAssistantText: String

    /// Hard cap. The checkpoint has to survive being written inside a few
    /// seconds of expiration grace, so it must never grow to the size of a
    /// streamed HTML mini-app.
    static let maxPartialChars = 8_000
}

/// Where the checkpoint lives.
///
/// Deliberately its OWN small file rather than a field in `ChatSession`'s
/// `Snapshot`: that snapshot is an atomic rewrite of every conversation and
/// can be multiple megabytes, which is not something to start when iOS has
/// already announced it is taking the process back.
enum PendingTurnStore {
    /// Test seam — unit tests point this at a temporary directory.
    static var directoryOverride: URL?

    private static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var url: URL { directory.appendingPathComponent("pending-turn.json") }

    static func save(_ turn: PendingTurn) {
        var trimmed = turn
        if trimmed.partialAssistantText.count > PendingTurn.maxPartialChars {
            trimmed.partialAssistantText = String(
                trimmed.partialAssistantText.suffix(PendingTurn.maxPartialChars)
            )
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> PendingTurn? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PendingTurn.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What the app should do with a checkpoint it finds on foreground / launch.
enum TurnRestoreDecision: Equatable {
    /// Nothing to do (no checkpoint, or one too old to be worth offering).
    case none
    /// The user pressed Stop — throw the checkpoint away and repair the thread.
    case discardCancelledTurn
    /// Offer the user a "fortsetzen" affordance for this turn.
    case offerResume(PendingTurn)
}

/// THE ordering-of-checks contract between the Live Activity's Stop button and
/// the interrupted-turn resume path.
///
/// **STOP BEATS RESUME.** The two features arrive at the same moment from
/// opposite directions: Stop persists `aiity.stopRequestedAt` for the
/// suspended/terminated case, and the checkpoint asks to replay an interrupted
/// turn. A turn the user cancelled from the Lock Screen must never come back
/// to life, so:
///
///  * the resume path examines the stop request FIRST and, if one is pending,
///    deletes the checkpoint and replays nothing (`discardCancelledTurn`);
///  * conversely `ChatSession.stop()` deletes the checkpoint, so an in-app
///    stop leaves nothing to resume either.
///
/// The one nuance: a stop request that predates the checkpointed turn belongs
/// to an *earlier* turn and must not cancel this one. In practice `send()`
/// also clears the flag at turn start, so that case is defensive only — but it
/// is cheap, and getting it wrong means silently eating a legitimate resume.
enum TurnRestorePolicy {
    /// How long a checkpoint stays worth offering. Generous, because the offer
    /// is a button and not a silent replay.
    static let resumeOfferWindow: TimeInterval = 60 * 60

    static func decide(
        stopRequestedAt: Date?,
        pending: PendingTurn?,
        now: Date = Date(),
        maxAge: TimeInterval = resumeOfferWindow
    ) -> TurnRestoreDecision {
        // 1. Stop first, always.
        if let stopRequestedAt {
            guard let pending else { return .discardCancelledTurn }
            if stopRequestedAt >= pending.startedAt { return .discardCancelledTurn }
            // Older than the turn: a leftover flag, not a cancellation of it.
        }
        // 2. Only then consider resuming.
        guard let pending else { return .none }
        guard now.timeIntervalSince(pending.updatedAt) <= maxAge else { return .none }
        return .offerResume(pending)
    }
}

/// Distinguishes "iOS suspended us mid-stream" from "the network is broken".
///
/// They surface identically — a frozen socket eventually throws `URLError` —
/// but they deserve opposite UI: the first is a pause with a resume offer, the
/// second is a genuine error banner.
enum TurnInterruptionPolicy {
    /// Codes a socket frozen by process suspension actually produces.
    static let suspensionCodes: Set<URLError.Code> = [
        .networkConnectionLost,
        .timedOut,
        .notConnectedToInternet,
        .cannotConnectToHost,
        .cannotFindHost,
        .dataNotAllowed,
        .backgroundSessionWasDisconnected
    ]

    static func isBackgroundInterruption(error: Error, wasBackgrounded: Bool) -> Bool {
        // Without the backgrounded flag this is just a network fault, and
        // dressing a real outage up as "pausiert" would be a lie.
        guard wasBackgrounded else { return false }
        guard let urlError = error as? URLError else { return false }
        return suspensionCodes.contains(urlError.code)
    }
}
