import CloudKit
import Foundation

/// What a CloudKit failure actually says, once `partialFailure` has been
/// unwrapped.
///
/// `CKError.partialFailure` (code 2) is a *container*: it means "this batch had
/// per-item failures", and it carries no reason of its own. The reasons live in
/// `partialErrorsByItemID`, one error per record. Surfacing the container —
/// "CKErrorDomain-Fehler 2" — is therefore the one thing that tells nobody
/// anything, neither the user nor whoever reads a diagnostics report later.
///
/// Two details make the unwrap worth doing properly rather than reading the
/// first value out of the dictionary:
///
/// 1. **`batchRequestFailed` (22) is noise.** When one record in a batch is
///    rejected, CloudKit fails the whole batch and marks every *other* record
///    with `batchRequestFailed`. On a 20-app library that is 19 useless entries
///    around the single one that names the cause, so it is demoted below every
///    other reason when choosing what to tell the user.
/// 2. **Partial failures nest.** A per-item error can itself be a
///    `partialFailure` (zone-level operations do this), so flattening is
///    recursive.
///
/// The server-side text (`ServerErrorDescription`) is the part that names the
/// record type and field — it is what distinguishes "your iCloud is full" from
/// "this record type was never deployed to the production schema". It is kept
/// verbatim for the diagnostics report and never shown to the user.
struct CloudKitErrorDigest: Equatable, Sendable {

    /// One distinct failure reason, with how many records hit it.
    struct Reason: Equatable, Sendable {
        var domain: String
        var code: Int
        /// CloudKit's own server text, when present. Names the record type.
        var serverMessage: String?
        /// The per-item error's `localizedDescription`, as a fallback.
        var localizedDescription: String
        var count: Int
        /// Up to `maxSampleItems` record identifiers, for the report.
        var items: [String]

        var isCloudKit: Bool { domain == CKErrorDomain }
        var ckCode: CKError.Code? { isCloudKit ? CKError.Code(rawValue: code) : nil }

        /// Distinct reasons are bucketed by domain + code + server text: the
        /// same code with two different server messages is two different
        /// problems.
        var bucketKey: String { "\(domain)|\(code)|\(serverMessage ?? "")" }
    }

    /// The outermost error, kept so a report can still show what CloudKit
    /// literally returned.
    var topDomain: String
    var topCode: Int
    var topDescription: String

    /// Distinct per-item reasons, most frequent first. Empty when the error
    /// carried no per-item detail at all.
    var reasons: [Reason]

    private static let maxSampleItems = 3
    /// Nested partials are legal; a cycle is not, but a malformed userInfo
    /// could still make one. Bounded rather than trusted.
    private static let maxDepth = 4

    // MARK: - Parsing

    static func make(from error: Error) -> CloudKitErrorDigest {
        let ns = error as NSError
        var buckets: [String: Reason] = [:]
        var order: [String] = []
        flatten(ns, item: nil, depth: 0, buckets: &buckets, order: &order)

        // Stable ordering: most-hit reason first, ties broken by discovery
        // order so the same failure renders identically every time.
        let ranked = order.compactMap { buckets[$0] }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.count != rhs.element.count { return lhs.element.count > rhs.element.count }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        return CloudKitErrorDigest(
            topDomain: ns.domain,
            topCode: ns.code,
            topDescription: ns.localizedDescription,
            reasons: ranked
        )
    }

    private static func flatten(
        _ error: NSError,
        item: String?,
        depth: Int,
        buckets: inout [String: Reason],
        order: inout [String]
    ) {
        if depth <= maxDepth,
           let partials = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
           !partials.isEmpty {
            // The container itself contributes nothing — only its children do.
            // Sorted so a dictionary's arbitrary iteration order cannot make
            // two reports of the same failure disagree.
            for key in partials.keys.sorted(by: { itemLabel($0) < itemLabel($1) }) {
                guard let sub = partials[key] else { continue }
                flatten(
                    sub as NSError,
                    item: itemLabel(key),
                    depth: depth + 1,
                    buckets: &buckets,
                    order: &order
                )
            }
            return
        }

        var reason = Reason(
            domain: error.domain,
            code: error.code,
            serverMessage: serverMessage(in: error),
            localizedDescription: error.localizedDescription,
            count: 0,
            items: []
        )
        let key = reason.bucketKey
        if var existing = buckets[key] {
            existing.count += 1
            if let item, existing.items.count < maxSampleItems { existing.items.append(item) }
            buckets[key] = existing
        } else {
            reason.count = 1
            if let item { reason.items = [item] }
            buckets[key] = reason
            order.append(key)
        }
    }

    /// CloudKit has no public constant for the server text; it has shipped
    /// under both of these keys, and Core Data adds a failure reason of its
    /// own. Read all of them rather than pick one and lose the message on the
    /// OS version that uses the other.
    private static func serverMessage(in error: NSError) -> String? {
        let candidates = [
            "ServerErrorDescription",
            "CKErrorDescription",
            NSLocalizedFailureReasonErrorKey,
        ]
        for key in candidates {
            if let text = error.userInfo[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// `partialErrorsByItemID` is keyed by `CKRecord.ID` (or a zone ID), whose
    /// `description` is a long pointer-bearing debug string. Only the record
    /// name is useful, and only the leading part of it.
    static func itemLabel(_ key: AnyHashable) -> String {
        if let recordID = key.base as? CKRecord.ID { return String(recordID.recordName.prefix(20)) }
        if let zoneID = key.base as? CKRecordZone.ID { return zoneID.zoneName }
        let described = String(describing: key.base)
        if let range = described.range(of: "recordName=") {
            let tail = described[range.upperBound...]
            let name = tail.prefix(while: { $0 != "," && $0 != ";" && $0 != ">" })
            if !name.isEmpty { return String(name.prefix(20)) }
        }
        return String(described.prefix(40))
    }

    // MARK: - What to tell the user

    /// `batchRequestFailed` only ever means "another record in the same batch
    /// was rejected" — it is a consequence, never a cause. Everything else
    /// outranks it.
    private static func isCollateral(_ reason: Reason) -> Bool {
        reason.ckCode == .batchRequestFailed
    }

    /// The reasons worth showing: the real causes if there are any, otherwise
    /// whatever there is (an all-collateral digest still beats saying nothing).
    var significantReasons: [Reason] {
        let real = reasons.filter { !CloudKitErrorDigest.isCollateral($0) }
        return real.isEmpty ? reasons : real
    }

    /// One German sentence the user can act on. Never a raw error number.
    var userMessage: String {
        guard let primary = significantReasons.first else {
            // A partial failure with no per-item errors at all: CloudKit gave
            // us nothing to unwrap. Say that instead of inventing a cause.
            return topDescription.isEmpty
                ? String(localized: "iCloud hat den Abgleich abgelehnt, ohne einen Grund zu nennen. Deine Daten sind lokal vollständig.")
                : topDescription
        }

        var message = CloudKitErrorDigest.advice(for: primary)
        let others = significantReasons.count - 1
        if others > 0 {
            message += " " + String(localized: "(und \(others) weitere(r) Grund/Gründe — Details unter Mehr → Diagnose)")
        }
        return message
    }

    /// German, actionable, and specific about whose problem it is. The rule
    /// here is the same one the diagnostics report follows: never imply the
    /// user's data is gone — a rejected *export* means iCloud does not have the
    /// record, not that the device lost it.
    static func advice(for reason: Reason) -> String {
        guard let code = reason.ckCode else {
            // Not CloudKit at all (Core Data, URLError, a test double).
            return reason.localizedDescription
        }
        switch code {
        case .quotaExceeded:
            return String(localized: "Dein iCloud-Speicher ist voll. Schaffe in den iOS-Einstellungen unter Apple-ID → iCloud Platz — bis dahin bleiben neue Mini-Apps nur auf diesem Gerät.")
        case .limitExceeded:
            return String(localized: "Eine Mini-App ist zu groß für iCloud (Grenze: 1 MB pro Eintrag). Sie bleibt auf diesem Gerät nutzbar; verkleinere sie oder entferne eingebettete Bilder, damit sie synchronisiert.")
        case .notAuthenticated:
            return String(localized: "Du bist nicht bei iCloud angemeldet. Melde dich in den iOS-Einstellungen an, dann synchronisiert die App weiter.")
        case .permissionFailure:
            return String(localized: "iCloud verweigert den Zugriff. Prüfe in den iOS-Einstellungen unter Apple-ID → iCloud, ob iCloud Drive und aiity erlaubt sind.")
        case .managedAccountRestricted:
            return String(localized: "Dein iCloud-Account ist eingeschränkt (verwaltetes Gerät oder Bildschirmzeit). Deine Mini-Apps bleiben vollständig auf diesem Gerät.")
        case .accountTemporarilyUnavailable:
            return String(localized: "iCloud ist gerade nicht verfügbar. Die App versucht es von selbst erneut — es geht nichts verloren.")
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return String(localized: "iCloud ist im Moment nicht erreichbar. Die App versucht es von selbst erneut — es geht nichts verloren.")
        case .serverRecordChanged, .changeTokenExpired:
            return String(localized: "Ein Eintrag wurde auf zwei Geräten gleichzeitig geändert. Die zuletzt gespeicherte Fassung gewinnt; nichts wird gelöscht.")
        case .zoneNotFound, .userDeletedZone:
            return String(localized: "Der iCloud-Bereich dieser App existiert nicht mehr — er wird beim nächsten Start neu angelegt. Deine Mini-Apps auf diesem Gerät sind davon nicht betroffen.")
        case .unknownItem, .invalidArguments, .constraintViolation, .serverRejectedRequest, .incompatibleVersion:
            // The schema class. Nothing the user can fix, and saying "try
            // again" would be a lie — so say plainly that it is the app's
            // problem, and that local data is fine.
            return String(localized: "iCloud lehnt das Datenformat dieser App-Version ab — das muss die App-Seite beheben, du kannst nichts tun. Deine Mini-Apps bleiben auf diesem Gerät vollständig erhalten. Bitte schicke uns den Bericht unter Mehr → Diagnose.")
        case .badContainer, .missingEntitlement, .badDatabase:
            return String(localized: "Die iCloud-Anbindung dieser App-Version ist nicht korrekt eingerichtet — das lässt sich nur app-seitig beheben. Deine Mini-Apps bleiben auf diesem Gerät vollständig erhalten.")
        case .batchRequestFailed:
            return String(localized: "Der Eintrag wurde zusammen mit einem anderen abgelehnt. Der eigentliche Grund steht unter Mehr → Diagnose.")
        case .partialFailure:
            // Reached only when the partial dictionary was empty — CloudKit
            // said "some items failed" and then listed none.
            return String(localized: "iCloud hat einzelne Einträge abgelehnt, nennt dazu aber keinen Grund. Deine Daten sind auf diesem Gerät vollständig; bitte schicke uns den Bericht unter Mehr → Diagnose.")
        case .operationCancelled:
            return String(localized: "Der Abgleich wurde abgebrochen und läuft beim nächsten Start weiter.")
        default:
            return String(localized: "iCloud meldet einen Fehler, den die App nicht einordnen kann (\(codeName(code))). Details stehen unter Mehr → Diagnose; deine Daten sind lokal vollständig.")
        }
    }

    /// The CKError case name — developer-facing, English on purpose: it is what
    /// Apple's documentation and every search result call it.
    static func codeName(_ code: CKError.Code) -> String {
        switch code {
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .badContainer: return "badContainer"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .missingEntitlement: return "missingEntitlement"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .unknownItem: return "unknownItem"
        case .invalidArguments: return "invalidArguments"
        case .serverRecordChanged: return "serverRecordChanged"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .assetFileNotFound: return "assetFileNotFound"
        case .assetFileModified: return "assetFileModified"
        case .incompatibleVersion: return "incompatibleVersion"
        case .constraintViolation: return "constraintViolation"
        case .operationCancelled: return "operationCancelled"
        case .changeTokenExpired: return "changeTokenExpired"
        case .batchRequestFailed: return "batchRequestFailed"
        case .zoneBusy: return "zoneBusy"
        case .badDatabase: return "badDatabase"
        case .quotaExceeded: return "quotaExceeded"
        case .zoneNotFound: return "zoneNotFound"
        case .limitExceeded: return "limitExceeded"
        case .userDeletedZone: return "userDeletedZone"
        case .tooManyParticipants: return "tooManyParticipants"
        case .alreadyShared: return "alreadyShared"
        case .referenceViolation: return "referenceViolation"
        case .managedAccountRestricted: return "managedAccountRestricted"
        case .participantMayNeedVerification: return "participantMayNeedVerification"
        case .serverResponseLost: return "serverResponseLost"
        case .assetNotAvailable: return "assetNotAvailable"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        @unknown default: return "unknown(\(code.rawValue))"
        }
    }

    // MARK: - What to put in the diagnostics report

    /// Developer-facing detail, one line per distinct reason. This is the part
    /// that makes a report from a real device actionable: the server message
    /// names the record type and the field.
    var diagnosticLines: [String] {
        var out = ["Fehler: \(topDomain) \(topCode)\(CloudKitErrorDigest.suffix(domain: topDomain, code: topCode))"]
        if reasons.isEmpty {
            out.append("  (keine Einzelfehler in partialErrorsByItemID)")
            if !topDescription.isEmpty { out.append("  \(topDescription)") }
            return out
        }
        for reason in reasons {
            out.append(
                "  • \(reason.count)× \(reason.domain) \(reason.code)"
                + CloudKitErrorDigest.suffix(domain: reason.domain, code: reason.code)
            )
            if let server = reason.serverMessage {
                out.append("      Server: \(server)")
            } else if !reason.localizedDescription.isEmpty {
                out.append("      \(reason.localizedDescription)")
            }
            if !reason.items.isEmpty {
                let more = reason.count > reason.items.count ? ", …" : ""
                out.append("      Einträge: \(reason.items.joined(separator: ", "))\(more)")
            }
        }
        return out
    }

    private static func suffix(domain: String, code: Int) -> String {
        guard domain == CKErrorDomain, let ck = CKError.Code(rawValue: code) else { return "" }
        return " (\(codeName(ck)))"
    }
}
