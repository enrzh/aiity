import Foundation

/// Soft freemium limits. Kept high until real StoreKit ships — the point is a
/// hook, not friction.
enum FreeTier {
    static let maxSavedMiniApps = 100
    static let maxCustomSkills = 50

    nonisolated(unsafe) static var isPremium: Bool = {
        UserDefaults.standard.bool(forKey: "freemium.premium.v1")
    }() {
        didSet { UserDefaults.standard.set(isPremium, forKey: "freemium.premium.v1") }
    }

    /// When false, all gates pass (default for personal builds).
    nonisolated(unsafe) static var limitsEnabled: Bool = {
        UserDefaults.standard.object(forKey: "freemium.limitsEnabled.v1") as? Bool ?? false
    }() {
        didSet { UserDefaults.standard.set(limitsEnabled, forKey: "freemium.limitsEnabled.v1") }
    }

    static func canSaveMiniApp(currentCount: Int) -> Bool {
        if isPremium || !limitsEnabled { return true }
        return currentCount < maxSavedMiniApps
    }

    static func canInstallSkill(currentCustomCount: Int) -> Bool {
        if isPremium || !limitsEnabled { return true }
        return currentCustomCount < maxCustomSkills
    }

    static var miniAppLimitMessage: String {
        "Limit: \(maxSavedMiniApps) Mini-Apps. Lösche eine App oder aktiviere Pro (kommt später)."
    }

    static var skillLimitMessage: String {
        "Limit: \(maxCustomSkills) eigene Skills. Entferne einen Skill oder aktiviere Pro (kommt später)."
    }
}
