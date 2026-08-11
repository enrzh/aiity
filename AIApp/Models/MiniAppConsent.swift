import Foundation

/// Remembers a mini-app's capability tier and the public hosts it may reach.
/// The v2 payload is a Codable dictionary so future fields can be added without
/// changing the UserDefaults key again; v1 capability-only maps still migrate.
enum MiniAppConsent {
    private static let legacyKey = "miniapp-consent-v1"
    private static let recordsKey = "miniapp-consent-v2"

    private struct Record: Codable {
        var version: Int = 2
        var capability: MiniAppCapability
        var hosts: [String] = []

        init(capability: MiniAppCapability, hosts: [String] = []) {
            self.capability = capability
            self.hosts = hosts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            capability = try container.decode(MiniAppCapability.self, forKey: .capability)
            hosts = try container.decodeIfPresent([String].self, forKey: .hosts) ?? []
        }
    }

    static func granted(appId: String) -> MiniAppCapability? {
        record(appId: appId)?.capability
    }

    static func hosts(appId: String) -> [String] {
        record(appId: appId)?.hosts.compactMap(NetworkTargetValidator.normalizeHost).sorted() ?? []
    }

    /// Every grant the user has made, keyed by app id. Sweep callers only need
    /// the capability values, so the host detail stays behind this API.
    static func grants() -> [String: MiniAppCapability] {
        records().compactMapValues(\.capability)
    }

    static func revoke(appId: String) {
        var all = records()
        all.removeValue(forKey: appId)
        persist(all)
    }

    static func previewId(html: String) -> String {
        var h: UInt64 = 5381
        for b in html.utf8 { h = (h &* 33) &+ UInt64(b) }
        return "preview-" + String(h, radix: 16)
    }

    static func allow(appId: String, capability: MiniAppCapability, hosts: [String] = []) {
        var all = records()
        let existingHosts = all[appId]?.hosts ?? []
        all[appId] = Record(
            capability: capability,
            hosts: Set((hosts.isEmpty ? existingHosts : hosts)
                .compactMap(NetworkTargetValidator.normalizeHost)).sorted()
        )
        persist(all)
    }

    @discardableResult
    static func grantHost(appId: String, host: String) -> Bool {
        guard let normalized = NetworkTargetValidator.normalizeHost(host),
              var record = record(appId: appId) else { return false }
        guard !record.hosts.contains(normalized) else { return true }
        record.hosts.append(normalized)
        var all = records()
        all[appId] = record
        persist(all)
        return true
    }

    @discardableResult
    static func revokeHost(appId: String, host: String) -> Bool {
        guard let normalized = NetworkTargetValidator.normalizeHost(host),
              var record = record(appId: appId),
              let index = record.hosts.firstIndex(of: normalized) else { return false }
        record.hosts.remove(at: index)
        var all = records()
        all[appId] = record
        persist(all)
        return true
    }

    static func revokeAllHosts(appId: String) {
        guard var record = record(appId: appId) else { return }
        record.hosts = []
        var all = records()
        all[appId] = record
        persist(all)
    }

    static func isAllowed(appId: String, declared: MiniAppCapability) -> Bool {
        if declared == .offline { return true }
        guard let granted = granted(appId: appId) else { return false }
        return granted.rank >= declared.rank
    }

    private static func record(appId: String) -> Record? {
        records()[appId]
    }

    private static func records() -> [String: Record] {
        if let data = UserDefaults.standard.data(forKey: recordsKey),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            return decoded.mapValues { record in
                var record = record
                record.hosts = Set(record.hosts.compactMap(NetworkTargetValidator.normalizeHost)).sorted()
                return record
            }
        }

        guard let legacy = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: String] else {
            return [:]
        }
        let migrated = legacy.compactMapValues { raw in
            MiniAppCapability(rawValue: raw).map { Record(capability: $0) }
        }
        if !migrated.isEmpty { persist(migrated) }
        return migrated
    }

    private static func persist(_ records: [String: Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: recordsKey)
    }
}
