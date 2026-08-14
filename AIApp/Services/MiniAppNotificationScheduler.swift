import Foundation
import UserNotifications

/// `window.aiity.notifications` — consent-gated local notifications for
/// mini-apps. The per-app aiity consent happens in the runner (it needs the
/// presenting web view); this service owns everything after that consent: OS
/// authorization (lazily, on first granted use — never at launch), validation,
/// the 8-pending-per-app cap, and app-scoped identifiers so `cancelAll` and
/// the launch sweep can find exactly this app's requests.
///
/// Every result is a JSON-ready `{ok, ...}` dictionary, same contract as
/// `MiniAppNotificationService`.
enum MiniAppNotificationScheduler {
    static let maxPendingPerApp = 8
    /// `userInfo` key carrying the owning app id, so a tap on a delivered
    /// notification can route back into the mini-app.
    static let userInfoAppIdKey = "aiityMiniAppId"

    private static let ledgerKey = "miniapp-notification-apps-v1"

    /// The `UNUserNotificationCenter` surface this needs, behind a seam: unit
    /// tests cannot drive (and must never mutate) the process-wide center.
    /// Same reason `MiniAppSessionStoreSweep.StoreIndex` exists for WebKit.
    struct Center {
        var gate: () async -> NotificationGate.Decision
        var requestAuthorization: () async -> Bool
        var add: (UNNotificationRequest) async throws -> Void
        var pendingIdentifiers: () async -> [String]
        var removePending: ([String]) -> Void

        static let current = Center(
            gate: { await AppNotifications.gate() },
            requestAuthorization: {
                (try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])) ?? false
            },
            add: { try await UNUserNotificationCenter.current().add($0) },
            pendingIdentifiers: {
                await withCheckedContinuation { continuation in
                    UNUserNotificationCenter.current().getPendingNotificationRequests {
                        continuation.resume(returning: $0.map(\.identifier))
                    }
                }
            },
            removePending: {
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(withIdentifiers: $0)
            }
        )
    }

    /// Test seam, `MiniAppNotificationService.gateOverride` style.
    static var centerOverride: Center?
    private static var center: Center { centerOverride ?? .current }

    // MARK: - Identifiers

    static func identifierPrefix(appId: String) -> String { "miniapp-\(appId)-" }

    /// Inverts `identifierPrefix(appId:) + UUID`. App ids contain hyphens
    /// themselves, so the trailing UUID is peeled off by shape, not by
    /// splitting — and the legacy `miniapp-<uuid>` ids of
    /// `MiniAppNotificationService` come back as `nil`, not as an empty app.
    static func appId(fromIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix("miniapp-") else { return nil }
        let rest = identifier.dropFirst("miniapp-".count)
        guard let cut = rest.index(rest.endIndex, offsetBy: -37, limitedBy: rest.startIndex),
              cut > rest.startIndex,
              rest[cut] == "-",
              UUID(uuidString: String(rest[rest.index(after: cut)...])) != nil
        else { return nil }
        return String(rest[..<cut])
    }

    // MARK: - Schedule / cancel

    static func schedule(
        appId: String, title: String, body: String, at: Any?, now: Date = Date()
    ) async -> [String: Any] {
        guard let fire = fireDate(from: at) else { return ["ok": false, "error": "invalid_date"] }
        guard fire > now else { return ["ok": false, "error": "date_in_past"] }

        let prefix = identifierPrefix(appId: appId)
        let mine = await center.pendingIdentifiers().filter { $0.hasPrefix(prefix) }
        guard mine.count < maxPendingPerApp else { return ["ok": false, "error": "limit_exceeded"] }

        switch await center.gate() {
        case .post:
            break
        case .ask:
            // First use, and by construction a moment with user context — the
            // user just granted this app the aiity consent in the foreground.
            guard await center.requestAuthorization() else {
                return ["ok": false, "error": "permission_denied"]
            }
        case .refuse:
            return ["ok": false, "error": "permission_denied"]
        }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? String(localized: "Mini-App") : String(title.prefix(80))
        content.body = String(body.prefix(300))
        content.sound = .default
        content.userInfo = [userInfoAppIdKey: appId]
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, fire.timeIntervalSince(now)), repeats: false
        )
        let identifier = prefix + UUID().uuidString
        do {
            try await center.add(UNNotificationRequest(
                identifier: identifier, content: content, trigger: trigger
            ))
            noteScheduled(appId)
            return ["ok": true, "id": identifier]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    /// Removes every pending request of this app and returns how many went.
    static func cancelAll(appId: String) async -> Int {
        let prefix = identifierPrefix(appId: appId)
        let mine = await center.pendingIdentifiers().filter { $0.hasPrefix(prefix) }
        if !mine.isEmpty { center.removePending(mine) }
        forgetScheduled(appId)
        return mine.count
    }

    /// `at` from the bridge: epoch milliseconds or an ISO 8601 string.
    static func fireDate(from value: Any?) -> Date? {
        if let ms = value as? NSNumber {
            return Date(timeIntervalSince1970: ms.doubleValue / 1000)
        }
        if let iso = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        }
        return nil
    }

    // MARK: - Ledger

    // Why a durable ledger and not the grant map or the center itself: the
    // sweep needs a cheap, kill-proof trigger for "this app id may still have
    // pending requests". The grant map cannot be it — a local delete revokes
    // the grant in the same breath, which would strand the notifications the
    // way jars used to strand (see MiniAppSessionStorePurgeQueue) — and asking
    // the center on every launch just to learn there is nothing to do is the
    // cost the ledger avoids.

    /// Every app id that has ever scheduled and not since had everything
    /// cancelled. A superset of the apps with live pending requests (fired
    /// notifications leave their entry behind), which only costs a no-op
    /// cancel on the next sweep pass.
    static func scheduledAppIds() -> [String] {
        (UserDefaults.standard.stringArray(forKey: ledgerKey) ?? []).sorted()
    }

    /// Overwrite the ledger — exists for the tests' snapshot/restore, like
    /// `MiniAppSessionStorePurgeQueue.replaceAll`.
    static func replaceScheduledAppIds(_ appIds: [String]) {
        UserDefaults.standard.set(appIds.sorted(), forKey: ledgerKey)
    }

    private static func noteScheduled(_ appId: String) {
        var all = Set(scheduledAppIds())
        guard all.insert(appId).inserted else { return }
        UserDefaults.standard.set(all.sorted(), forKey: ledgerKey)
    }

    private static func forgetScheduled(_ appId: String) {
        var all = Set(scheduledAppIds())
        guard all.remove(appId) != nil else { return }
        UserDefaults.standard.set(all.sorted(), forKey: ledgerKey)
    }
}

/// Tapping a delivered mini-app notification opens that mini-app, through the
/// same route Siri/Shortcuts use — `RootView.performIntentRoute` presents the
/// sheet whether the tap cold-launches or resumes the app. Lives here rather
/// than in AppNotifications.swift only to keep the mini-app wiring in one
/// place; the center keeps exactly one delegate, and this extends it.
extension AppNotificationDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let raw = response.notification.request.content
                .userInfo[MiniAppNotificationScheduler.userInfoAppIdKey] as? String,
              let id = UUID(uuidString: raw)
        else { return }
        // Preview-keyed apps have no library record; their taps just open the app.
        await MainActor.run {
            IntentRouter.shared.request(.openMiniApp(id: id))
        }
    }
}
