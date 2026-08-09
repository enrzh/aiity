import XCTest
import AVFoundation
import Speech
@testable import AIApp

/// Dictation is on-device ONLY: the audio must never leave the phone, and the
/// app must never quietly fall back to Apple's server-based recognition to
/// cover a gap. A microphone cannot be driven from a unit test (and the
/// simulator cannot record at all), so what is pinned here is the whole
/// decision surface around the recognizer: permission → next step, locale and
/// on-device gating, state → button visual, and transcript → composer text.
final class DictationTests: XCTestCase {

    // MARK: - Permission gate (first-tap policy)

    func testFirstTapAsksForSpeechBeforeMicrophone() {
        // Nothing is authorized yet — the very first thing the tap does is the
        // speech dialog. Asking for the microphone first would leave the user
        // with a granted mic and no recognizer.
        XCTAssertEqual(
            DictationPermissionGate.step(speech: .notDetermined, microphone: .undetermined),
            .requestSpeech
        )
        XCTAssertEqual(
            DictationPermissionGate.step(speech: .notDetermined, microphone: .granted),
            .requestSpeech
        )
    }

    func testMicrophoneIsAskedOnlyAfterSpeechIsAuthorized() {
        XCTAssertEqual(
            DictationPermissionGate.step(speech: .authorized, microphone: .undetermined),
            .requestMicrophone
        )
    }

    func testFullyAuthorizedGoesStraightToTheRecognizer() {
        XCTAssertEqual(
            DictationPermissionGate.step(speech: .authorized, microphone: .granted),
            .ready
        )
    }

    func testDenialsBlockInsteadOfRePrompting() {
        // A denied status must never map back to a request: iOS would not show
        // anything anyway, and the user would just see a dead button.
        XCTAssertEqual(
            DictationPermissionGate.step(speech: .denied, microphone: .granted),
            .blocked(.speechDenied)
        )
        XCTAssertEqual(
            DictationPermissionGate.step(speech: .restricted, microphone: .granted),
            .blocked(.speechRestricted)
        )
        XCTAssertEqual(
            DictationPermissionGate.step(speech: .authorized, microphone: .denied),
            .blocked(.microphoneDenied)
        )
    }

    func testDeniedPermissionsStayFixableInSettings() {
        // Denials are recoverable, so the button stays tappable and the alert
        // offers the Settings link; a policy restriction offers neither.
        XCTAssertTrue(DictationUnavailableReason.speechDenied.offersSettingsLink)
        XCTAssertTrue(DictationUnavailableReason.microphoneDenied.offersSettingsLink)
        XCTAssertFalse(DictationUnavailableReason.speechDenied.isPermanent)
        XCTAssertFalse(DictationUnavailableReason.microphoneDenied.isPermanent)

        XCTAssertTrue(DictationUnavailableReason.speechRestricted.isPermanent)
        XCTAssertFalse(DictationUnavailableReason.speechRestricted.offersSettingsLink)
    }

    // MARK: - Availability / locale gating

    func testOfflineCapableRecognizerIsAllowedToStart() {
        XCTAssertNil(
            DictationAvailability.reason(
                hasRecognizer: true, isAvailable: true, supportsOnDevice: true,
                languageName: "Deutsch"
            )
        )
    }

    func testLocaleWithoutAnyRecognizerIsReportedAsUnsupported() {
        XCTAssertEqual(
            DictationAvailability.reason(
                hasRecognizer: false, isAvailable: false, supportsOnDevice: false,
                languageName: "Suaheli"
            ),
            .localeUnsupported(languageName: "Suaheli")
        )
    }

    func testServerOnlyLocaleIsRefusedRatherThanSentToApplesServers() {
        // THE privacy-critical branch: a perfectly available recognizer that
        // has no offline model. Falling back would work and would be a lie, so
        // the feature degrades instead.
        XCTAssertEqual(
            DictationAvailability.reason(
                hasRecognizer: true, isAvailable: true, supportsOnDevice: false,
                languageName: "Deutsch"
            ),
            .onDeviceUnsupported(languageName: "Deutsch")
        )
        XCTAssertTrue(DictationUnavailableReason.onDeviceUnsupported(languageName: "Deutsch").isPermanent)
    }

    func testOnDeviceCheckOutranksTemporaryUnavailability() {
        // Both flags are false: "try again later" would be wrong, because no
        // amount of waiting produces an offline model here.
        XCTAssertEqual(
            DictationAvailability.reason(
                hasRecognizer: true, isAvailable: false, supportsOnDevice: false,
                languageName: "Deutsch"
            ),
            .onDeviceUnsupported(languageName: "Deutsch")
        )
    }

    func testOfflineCapableButMomentarilyUnavailableIsRetryable() {
        let reason = DictationAvailability.reason(
            hasRecognizer: true, isAvailable: false, supportsOnDevice: true,
            languageName: "Deutsch"
        )
        XCTAssertEqual(reason, .recognizerUnavailable)
        XCTAssertFalse(DictationUnavailableReason.recognizerUnavailable.isPermanent)
    }

    func testUnavailableMessagesAreGermanAndNameTheLanguage() {
        let message = DictationUnavailableReason.onDeviceUnsupported(languageName: "Französisch").message
        XCTAssertTrue(message.contains("Französisch"))
        XCTAssertTrue(message.contains("offline"))
    }

    func testLanguageNameIsHumanReadable() {
        let name = DictationAvailability.languageName(for: Locale(identifier: "de_DE"))
        XCTAssertFalse(name.isEmpty)
        XCTAssertNotEqual(name, "de_DE", "the raw identifier is not a language name")
    }

    // MARK: - State → button visual

    func testButtonStateMapping() {
        XCTAssertEqual(DictationButtonState.from(.idle), .idle)
        XCTAssertEqual(DictationButtonState.from(.listening), .listening)
        // A tap must light the button up immediately, even while the
        // permission round-trip is still in flight.
        XCTAssertEqual(DictationButtonState.from(.preparing), .listening)
        XCTAssertEqual(
            DictationButtonState.from(.unavailable(.onDeviceUnsupported(languageName: "Deutsch"))),
            .unavailable
        )
    }

    // MARK: - Transcript → composer text

    func testTranscriptFillsAnEmptyComposer() {
        XCTAssertEqual(DictationText.compose(base: "", transcript: "Hallo Welt"), "Hallo Welt")
    }

    func testTranscriptIsAppendedToWhatTheUserAlreadyTyped() {
        XCTAssertEqual(
            DictationText.compose(base: "Notiz:", transcript: "Milch kaufen"),
            "Notiz: Milch kaufen"
        )
        // An existing trailing space is not doubled.
        XCTAssertEqual(
            DictationText.compose(base: "Notiz: ", transcript: "Milch kaufen"),
            "Notiz: Milch kaufen"
        )
    }

    func testGrowingPartialsReplaceEachOtherInsteadOfStacking() {
        // Every partial is composed from the SAME base, which is what keeps
        // "Hallo" → "Hallo Welt" from becoming "Hallo Hallo Welt".
        let base = "Notiz:"
        var text = DictationText.compose(base: base, transcript: "Milch")
        text = DictationText.compose(base: base, transcript: "Milch kaufen")
        text = DictationText.compose(base: base, transcript: "Milch kaufen.")
        XCTAssertEqual(text, "Notiz: Milch kaufen.")
    }

    func testEmptyOrWhitespaceTranscriptLeavesTheComposerUntouched() {
        XCTAssertEqual(DictationText.compose(base: "Entwurf", transcript: ""), "Entwurf")
        XCTAssertEqual(DictationText.compose(base: "Entwurf", transcript: "   \n "), "Entwurf")
        XCTAssertEqual(DictationText.compose(base: "", transcript: "  "), "")
    }

    func testTranscriptEdgesAreTrimmed() {
        XCTAssertEqual(DictationText.compose(base: "", transcript: "  Hallo  "), "Hallo")
    }

    // MARK: - Service defaults

    @MainActor
    func testServiceStartsIdleAndAsksForNothingAtInit() {
        // Construction must be inert: the permission dialogs belong to the
        // first TAP, never to a view appearing.
        let service = DictationService()
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(service.buttonState, .idle)
        XCTAssertFalse(service.isListening)
        XCTAssertTrue(service.transcript.isEmpty)
        XCTAssertNil(service.notice)
    }

    func testAutoStopBoundsAreSane() {
        XCTAssertLessThanOrEqual(DictationService.maxDuration, 120)
        XCTAssertGreaterThan(DictationService.silenceTimeout, 1)
        XCTAssertLessThan(DictationService.silenceTimeout, DictationService.maxDuration)
    }
}
