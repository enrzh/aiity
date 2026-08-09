import Foundation
import AVFoundation
import Speech
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Vocabulary

/// Why dictation cannot run right now.
///
/// Every case is a HONEST dead end: the app never falls back to Apple's
/// server-based recognition to paper one of them over. On-device-only is a
/// product promise (the audio must not leave the phone), so "we could still do
/// it, just in the cloud" is not an option this type can express.
enum DictationUnavailableReason: Equatable {
    /// No SFSpeechRecognizer exists for the user's locale at all.
    case localeUnsupported(languageName: String)
    /// A recognizer exists, but it cannot run OFFLINE for this locale — the
    /// only path left would be Apple's servers, which we refuse.
    case onDeviceUnsupported(languageName: String)
    /// The recognizer is momentarily unavailable (model still downloading,
    /// system under pressure). Retryable, unlike the two above.
    case recognizerUnavailable
    /// The user declined speech recognition in the system dialog.
    case speechDenied
    /// Speech recognition is blocked by policy (Screen Time / MDM).
    case speechRestricted
    /// The user declined microphone access.
    case microphoneDenied
    /// The audio pipeline refused to start.
    case audioSessionFailed

    /// True when nothing the user can do inside iOS will fix it — the mic
    /// button stays disabled instead of pretending to be tappable.
    var isPermanent: Bool {
        switch self {
        case .localeUnsupported, .onDeviceUnsupported, .speechRestricted:
            return true
        case .recognizerUnavailable, .speechDenied, .microphoneDenied, .audioSessionFailed:
            return false
        }
    }

    /// Denials are fixable in Settings; everything else has no such link.
    var offersSettingsLink: Bool {
        switch self {
        case .speechDenied, .microphoneDenied: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .localeUnsupported, .onDeviceUnsupported:
            return String(localized: "Diktat für deine Sprache nicht offline verfügbar")
        case .recognizerUnavailable:
            return String(localized: "Diktat gerade nicht verfügbar")
        case .speechDenied, .speechRestricted:
            return String(localized: "Spracherkennung nicht erlaubt")
        case .microphoneDenied:
            return String(localized: "Mikrofon nicht erlaubt")
        case .audioSessionFailed:
            return String(localized: "Aufnahme konnte nicht starten")
        }
    }

    var message: String {
        switch self {
        case .localeUnsupported(let language):
            return String(localized: "Für \(language) gibt es auf diesem Gerät keine Spracherkennung. aiity diktiert ausschließlich offline — deine Stimme verlässt das Gerät nie —, deshalb gibt es hier keine Alternative über das Internet.")
        case .onDeviceUnsupported(let language):
            return String(localized: "\(language) kann auf diesem Gerät nur über Apples Server erkannt werden. aiity diktiert ausschließlich offline, deshalb ist das Diktat für diese Sprache deaktiviert. Lade die Sprache in den iOS-Einstellungen unter Allgemein › Tastatur › Diktat herunter, falls verfügbar.")
        case .recognizerUnavailable:
            return String(localized: "Die Offline-Spracherkennung ist gerade nicht bereit. Versuch es in einem Moment noch einmal.")
        case .speechDenied:
            return String(localized: "Du hast die Spracherkennung abgelehnt. Du kannst sie in den Einstellungen wieder erlauben — die Erkennung läuft weiterhin nur auf deinem Gerät.")
        case .speechRestricted:
            return String(localized: "Spracherkennung ist auf diesem Gerät gesperrt (z. B. durch Bildschirmzeit oder eine Geräteverwaltung).")
        case .microphoneDenied:
            return String(localized: "Ohne Mikrofonzugriff kann nicht diktiert werden. Du kannst ihn in den Einstellungen erlauben — die Aufnahme wird nur auf dem Gerät verarbeitet.")
        case .audioSessionFailed:
            return String(localized: "Das Mikrofon konnte nicht gestartet werden. Läuft gerade eine andere Aufnahme oder ein Anruf?")
        }
    }
}

/// What the composer's mic button is doing.
enum DictationState: Equatable {
    case idle
    /// Permission round-trip / audio start — button is busy but not recording.
    case preparing
    case listening
    case unavailable(DictationUnavailableReason)
}

/// The three visuals the mic button can take. Kept separate from
/// `DictationState` so the mapping is a pure function the tests can pin.
enum DictationButtonState: Equatable {
    case idle
    case listening
    case unavailable

    static func from(_ state: DictationState) -> DictationButtonState {
        switch state {
        case .idle: return .idle
        // `preparing` reads as listening: the user tapped, the button must
        // respond immediately rather than sit idle through a permission
        // round-trip.
        case .preparing, .listening: return .listening
        case .unavailable: return .unavailable
        }
    }
}

// MARK: - Pure policy (unit-testable without a microphone)

/// The permission policy, isolated from the OS so it can be tested.
///
/// Same rule the notification gate follows (see `NotificationGate`): a system
/// dialog may only appear as the direct result of a FOREGROUND user action —
/// here, the first tap on the mic button. Nothing asks at launch or init.
enum DictationPermissionGate {
    enum Step: Equatable {
        /// Both authorizations exist — go straight to the recognizer.
        case ready
        /// Show the speech-recognition dialog now (user just tapped).
        case requestSpeech
        /// Speech is granted; show the microphone dialog now.
        case requestMicrophone
        /// Nothing to ask for — surface the reason instead.
        case blocked(DictationUnavailableReason)
    }

    /// Speech authorization is resolved FIRST: without it a granted microphone
    /// is useless, and asking for the mic first would leave the user with a
    /// dialog they cannot benefit from.
    static func step(
        speech: SFSpeechRecognizerAuthorizationStatus,
        microphone: AVAudioApplication.recordPermission
    ) -> Step {
        switch speech {
        case .notDetermined:
            return .requestSpeech
        case .denied:
            return .blocked(.speechDenied)
        case .restricted:
            return .blocked(.speechRestricted)
        case .authorized:
            break
        @unknown default:
            return .blocked(.speechRestricted)
        }

        switch microphone {
        case .undetermined: return .requestMicrophone
        case .denied: return .blocked(.microphoneDenied)
        case .granted: return .ready
        @unknown default: return .blocked(.microphoneDenied)
        }
    }
}

/// Locale / on-device gating, isolated from `SFSpeechRecognizer` so the
/// "offline recognition does not exist for this language" path is testable —
/// it is the one branch a simulator can never reach on its own.
enum DictationAvailability {
    /// - Parameters:
    ///   - hasRecognizer: `SFSpeechRecognizer(locale:)` returned an instance.
    ///   - isAvailable: the recognizer's `isAvailable` flag.
    ///   - supportsOnDevice: the recognizer's `supportsOnDeviceRecognition`.
    ///   - languageName: display name for the message.
    /// - Returns: `nil` when dictation may start, otherwise the honest reason.
    static func reason(
        hasRecognizer: Bool,
        isAvailable: Bool,
        supportsOnDevice: Bool,
        languageName: String
    ) -> DictationUnavailableReason? {
        guard hasRecognizer else { return .localeUnsupported(languageName: languageName) }
        // Checked BEFORE `isAvailable`: a recognizer with no offline model is
        // permanently useless to us even while it is happily "available" for
        // server-based recognition, and saying "try again later" there would
        // be a lie.
        guard supportsOnDevice else { return .onDeviceUnsupported(languageName: languageName) }
        guard isAvailable else { return .recognizerUnavailable }
        return nil
    }

    /// Human-readable language for the current locale, e.g. "Deutsch".
    static func languageName(for locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier)
            ?? locale.language.languageCode?.identifier
            ?? locale.identifier
    }
}

/// How a live transcript lands in the composer.
///
/// Dictation APPENDS to whatever the user already typed and never replaces it;
/// each partial result recomputes the whole string from the same base, so
/// growing partials do not stack up.
enum DictationText {
    static func compose(base: String, transcript: String) -> String {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return base }
        guard !base.isEmpty else { return spoken }
        if base.last?.isWhitespace == true { return base + spoken }
        return base + " " + spoken
    }
}

// MARK: - Service

/// On-device speech-to-text for the chat composer.
///
/// Hard constraints, all of them product promises rather than implementation
/// details:
/// * `requiresOnDeviceRecognition = true` — audio never leaves the phone and
///   is never handed to a model provider. There is no server fallback.
/// * Permissions are requested from the mic button's FIRST TAP only.
/// * The audio session is deactivated with `.notifyOthersOnDeactivation` on
///   every exit path; a session left active ducks or mutes other apps' audio.
@MainActor
final class DictationService: NSObject, ObservableObject {
    /// Hard cap on a single dictation, so a forgotten tap cannot hold the
    /// microphone (and duck the user's music) indefinitely.
    static let maxDuration: TimeInterval = 60
    /// Stop once the transcript has not moved for this long.
    static let silenceTimeout: TimeInterval = 2.5

    @Published private(set) var state: DictationState = .idle
    /// Best transcript so far, partials included. Empty until the first result.
    @Published private(set) var transcript: String = ""
    /// Set when something must be explained to the user; the composer presents
    /// it and clears it.
    @Published var notice: DictationUnavailableReason?

    var isListening: Bool { DictationButtonState.from(state) == .listening }
    var buttonState: DictationButtonState { DictationButtonState.from(state) }

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var watchdog: Task<Void, Never>?
    private var release: Task<Void, Never>?
    private var lastResultAt = Date.distantPast

    // MARK: Entry point

    /// The mic button's only action. Called from a tap, never from init or a
    /// background path — that is what keeps the system dialogs in context.
    func toggle() {
        if isListening {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isListening else { return }
        state = .preparing

        switch await resolvePermissions() {
        case .blocked(let reason):
            fail(reason)
            return
        case .granted:
            break
        }
        // A second tap (or a screen exit) during the permission round-trip
        // means the user no longer wants this — never start the engine behind
        // their back.
        guard state == .preparing else { return }

        let locale = Locale.current
        let recognizer = SFSpeechRecognizer(locale: locale)
        recognizer?.delegate = self
        if let reason = DictationAvailability.reason(
            hasRecognizer: recognizer != nil,
            isAvailable: recognizer?.isAvailable ?? false,
            supportsOnDevice: recognizer?.supportsOnDeviceRecognition ?? false,
            languageName: DictationAvailability.languageName(for: locale)
        ) {
            fail(reason)
            return
        }
        guard let recognizer else { return }
        self.recognizer = recognizer

        do {
            try beginCapture(with: recognizer)
        } catch {
            teardownAudio()
            fail(.audioSessionFailed)
            return
        }

        transcript = ""
        lastResultAt = Date()
        state = .listening
        Theme.Haptics.tap()
        startWatchdog()
    }

    /// Ends the capture. The recognition task is left alive briefly so the
    /// final (punctuated) result can still land in the composer.
    func stop() {
        guard state == .listening || state == .preparing else { return }
        watchdog?.cancel(); watchdog = nil
        teardownAudio()
        state = .idle
        // Committing the transcript into the composer — the same haptic the
        // send button uses.
        Theme.Haptics.send()
        scheduleRelease(after: 1.5)
    }

    /// Hard abort: leaving the screen, backgrounding, the user taking over the
    /// keyboard. No final result is awaited.
    func cancel() {
        watchdog?.cancel(); watchdog = nil
        teardownAudio()
        releaseNow()
        switch state {
        // A permanent block survives a cancel — nothing about leaving the
        // screen makes an absent offline model appear.
        case .unavailable: break
        default: state = .idle
        }
    }

    // MARK: Permissions

    private enum PermissionOutcome { case granted, blocked(DictationUnavailableReason) }

    private func resolvePermissions() async -> PermissionOutcome {
        // Loops at most twice: one dialog per round, re-reading the real status
        // afterwards instead of trusting the callback's shape.
        for _ in 0..<3 {
            let step = DictationPermissionGate.step(
                speech: SFSpeechRecognizer.authorizationStatus(),
                microphone: AVAudioApplication.shared.recordPermission
            )
            switch step {
            case .ready:
                return .granted
            case .blocked(let reason):
                return .blocked(reason)
            case .requestSpeech:
                await Self.requestSpeechAuthorization()
            case .requestMicrophone:
                await Self.requestMicrophonePermission()
            }
        }
        return .blocked(.speechDenied)
    }

    private static func requestSpeechAuthorization() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    private static func requestMicrophonePermission() async {
        _ = await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Capture

    private func beginCapture(with recognizer: SFSpeechRecognizer) throws {
        let session = AVAudioSession.sharedInstance()
        // `.record` + `.measurement` is the dictation configuration; ducking
        // (rather than interrupting) keeps a podcast alive underneath.
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // THE line that makes this feature honest. Without it the buffers go to
        // Apple's servers — which would break the app's privacy promise even
        // though the transcript would look identical.
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A tap left over from a previous run makes installTap throw.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Hop to the main actor with VALUE copies only — the result object
            // itself is not safe to carry across.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.handle(text: text, isFinal: isFinal, failed: failed)
            }
        }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        if let text, !text.isEmpty {
            transcript = text
            lastResultAt = Date()
        }
        guard isFinal || failed else { return }
        if state == .listening {
            watchdog?.cancel(); watchdog = nil
            teardownAudio()
            state = .idle
        }
        // A recognizer that gives up before producing a single word would
        // otherwise look like a dead button: the session just ends and nothing
        // lands in the composer. Say so. (With a transcript in hand there is
        // nothing to explain — the user got their text.)
        if failed, transcript.isEmpty {
            notice = .recognizerUnavailable
        }
        releaseNow()
    }

    /// Auto-stop: the hard duration cap, and silence after something was said.
    private func startWatchdog() {
        watchdog?.cancel()
        let deadline = Date().addingTimeInterval(Self.maxDuration)
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, self.state == .listening else { return }
                if Date() >= deadline { self.stop(); return }
                if !self.transcript.isEmpty,
                   Date().timeIntervalSince(self.lastResultAt) > Self.silenceTimeout {
                    self.stop()
                    return
                }
            }
        }
    }

    // MARK: Teardown

    /// Stops pulling audio. Deliberately does NOT deactivate the session yet —
    /// see `scheduleRelease`.
    private func teardownAudio() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
    }

    private func scheduleRelease(after seconds: TimeInterval) {
        release?.cancel()
        release = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.releaseNow()
        }
    }

    /// Idempotent. Every exit path ends here, because an audio session left
    /// active keeps other apps ducked (or silent) for as long as aiity lives.
    private func releaseNow() {
        release?.cancel(); release = nil
        task?.cancel(); task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fail(_ reason: DictationUnavailableReason) {
        notice = reason
        // Retryable reasons must not leave the button dead — only a permanent
        // one (no offline model for this language, policy block) does.
        state = reason.isPermanent ? .unavailable(reason) : .idle
        releaseNow()
    }

    /// Deep link to this app's own settings page, where mic and speech
    /// permission live. Nothing else in the flow can undo a denial.
    static func openSystemSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Availability changes

extension DictationService: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ recognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if available {
                if case .unavailable(.recognizerUnavailable) = self.state { self.state = .idle }
            } else if self.isListening {
                self.cancel()
                self.notice = .recognizerUnavailable
            }
        }
    }
}
