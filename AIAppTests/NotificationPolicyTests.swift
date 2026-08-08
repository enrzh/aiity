import XCTest
import UserNotifications
@testable import AIApp

/// The permission policy is "post only when allowed, ask only in the
/// foreground with user context, never re-prompt after a denial". The gate
/// enum carries that decision for both producers (agent completion and the
/// mini-app bridge), so its mapping is pinned here.
final class NotificationPolicyTests: XCTestCase {

    // MARK: - Gate decisions

    func testAuthorizedStatusesPostWithoutPrompting() {
        XCTAssertEqual(NotificationGate.decision(for: .authorized), .post)
        XCTAssertEqual(NotificationGate.decision(for: .provisional), .post)
        XCTAssertEqual(NotificationGate.decision(for: .ephemeral), .post)
    }

    func testNotDeterminedMayAskInForegroundContext() {
        XCTAssertEqual(NotificationGate.decision(for: .notDetermined), .ask)
    }

    func testDeniedNeverReprompts() {
        // A background caller maps .ask to "give up"; .refuse must never turn
        // back into a request from anywhere.
        XCTAssertEqual(NotificationGate.decision(for: .denied), .refuse)
    }

    // MARK: - Mini-app bridge contract

    func testScheduleKeepsPermissionDeniedShapeWhenRefused() async {
        // A previously denied user must get the documented {ok:false,
        // permission_denied} shape back — with no requestAuthorization call,
        // which the .refuse branch returns before ever reaching.
        MiniAppNotificationService.gateOverride = .refuse
        defer { MiniAppNotificationService.gateOverride = nil }

        let result = await MiniAppNotificationService.schedule(
            title: "Test", body: "Body", inSeconds: 5
        )
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "permission_denied")
    }
}
