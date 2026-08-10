import CloudKit
import XCTest
@testable import AIApp

/// A real `CKError.partialFailure` cannot be produced on a machine without an
/// iCloud account, and the simulator has none — so these build the payload
/// CloudKit would hand over (`NSError` in `CKErrorDomain` carrying
/// `CKPartialErrorsByItemIDKey`) and check the unwrapping against it.
///
/// What they can prove: that the per-record reasons are found, deduplicated,
/// ranked, and turned into a sentence rather than "CKErrorDomain-Fehler 2".
/// What they cannot prove: which reason a signed-in device actually reports.
final class CloudKitErrorDigestTests: XCTestCase {

    // MARK: - Builders

    private func ckError(
        _ code: CKError.Code,
        server: String? = nil,
        partials: [AnyHashable: Error]? = nil
    ) -> NSError {
        var info: [String: Any] = [
            NSLocalizedDescriptionKey: "Der Vorgang konnte nicht abgeschlossen werden. (CKErrorDomain-Fehler \(code.rawValue).)"
        ]
        if let server { info["ServerErrorDescription"] = server }
        if let partials { info[CKPartialErrorsByItemIDKey] = partials }
        return NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: info)
    }

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName))
    }

    // MARK: - Distinct reasons

    func testDistinctReasonsAreBucketedCountedAndRankedByFrequency() {
        let error = ckError(.partialFailure, partials: [
            recordID("A1"): ckError(.quotaExceeded),
            recordID("A2"): ckError(.quotaExceeded),
            recordID("A3"): ckError(.limitExceeded),
        ])

        let digest = CloudKitErrorDigest.make(from: error)

        XCTAssertEqual(digest.topCode, CKError.Code.partialFailure.rawValue)
        XCTAssertEqual(digest.reasons.count, 2, "two distinct codes, not three records")
        XCTAssertEqual(digest.reasons[0].code, CKError.Code.quotaExceeded.rawValue)
        XCTAssertEqual(digest.reasons[0].count, 2)
        XCTAssertEqual(digest.reasons[1].code, CKError.Code.limitExceeded.rawValue)
        XCTAssertEqual(digest.reasons[1].count, 1)

        // The most frequent real reason drives the sentence, and it is a
        // sentence — no bare error number anywhere in it.
        XCTAssertTrue(digest.userMessage.contains("iCloud-Speicher ist voll"))
        XCTAssertFalse(digest.userMessage.contains("CKErrorDomain"))
        XCTAssertTrue(digest.userMessage.contains("1 weitere"), "the second reason must not vanish silently")
    }

    func testSameCodeWithDifferentServerTextCountsAsTwoReasons() {
        let error = ckError(.partialFailure, partials: [
            recordID("A1"): ckError(.invalidArguments, server: "Unknown field 'CD_iconSymbol'"),
            recordID("A2"): ckError(.invalidArguments, server: "Cannot create new type CD_MiniApp in production schema"),
        ])

        let digest = CloudKitErrorDigest.make(from: error)
        XCTAssertEqual(digest.reasons.count, 2, "same code, different server text = different problem")
        let joined = digest.diagnosticLines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("CD_iconSymbol"))
        XCTAssertTrue(joined.contains("CD_MiniApp"))
    }

    // MARK: - batchRequestFailed is a consequence, never a cause

    func testTheOneRealReasonOutranksTheBatchCollateral() {
        var partials: [AnyHashable: Error] = [
            recordID("REAL"): ckError(.invalidArguments, server: "Cannot create new type CD_MiniApp in production schema")
        ]
        for index in 0..<9 {
            partials[recordID("B\(index)")] = ckError(.batchRequestFailed)
        }

        let digest = CloudKitErrorDigest.make(from: error(partials))

        // Ranking by count alone would put the 9 collateral entries first.
        XCTAssertEqual(digest.reasons.first?.code, CKError.Code.batchRequestFailed.rawValue)
        XCTAssertEqual(digest.significantReasons.count, 1)
        XCTAssertEqual(digest.significantReasons.first?.code, CKError.Code.invalidArguments.rawValue)
        XCTAssertTrue(digest.userMessage.contains("Datenformat"))
        XCTAssertFalse(digest.userMessage.contains("weitere"), "one real reason means no '+N more' tail")

        // The report still lists the collateral — it is evidence of scale.
        XCTAssertTrue(digest.diagnosticLines.joined().contains("batchRequestFailed"))
    }

    func testAnAllCollateralDigestStillSaysSomething() {
        let digest = CloudKitErrorDigest.make(from: error([
            recordID("B0"): ckError(.batchRequestFailed),
            recordID("B1"): ckError(.batchRequestFailed),
        ]))
        XCTAssertEqual(digest.significantReasons.count, 1, "falls back rather than showing nothing")
        XCTAssertFalse(digest.userMessage.isEmpty)
    }

    private func error(_ partials: [AnyHashable: Error]) -> NSError {
        ckError(.partialFailure, partials: partials)
    }

    // MARK: - Nesting

    func testNestedPartialFailuresAreFlattenedToTheirLeaves() {
        let inner = ckError(.partialFailure, partials: [
            recordID("C1"): ckError(.serverRecordChanged),
            recordID("C2"): ckError(.serverRecordChanged),
        ])
        let outer = ckError(.partialFailure, partials: [
            CKRecordZone.ID(zoneName: "zone", ownerName: CKCurrentUserDefaultName): inner,
            recordID("C3"): ckError(.quotaExceeded),
        ])

        let digest = CloudKitErrorDigest.make(from: outer)

        XCTAssertEqual(digest.reasons.count, 2)
        XCTAssertFalse(
            digest.reasons.contains { $0.code == CKError.Code.partialFailure.rawValue },
            "the container must not be reported as a reason of its own"
        )
        XCTAssertEqual(
            digest.reasons.first(where: { $0.code == CKError.Code.serverRecordChanged.rawValue })?.count, 2
        )
    }

    // MARK: - Degenerate payloads

    func testEmptyPartialDictionaryReportsTheContainerHonestly() {
        let digest = CloudKitErrorDigest.make(from: ckError(.partialFailure, partials: [:]))

        XCTAssertEqual(digest.reasons.count, 1)
        XCTAssertEqual(digest.reasons[0].code, CKError.Code.partialFailure.rawValue)
        XCTAssertTrue(digest.userMessage.contains("keinen Grund"))
        XCTAssertFalse(digest.userMessage.contains("CKErrorDomain-Fehler 2"))
    }

    func testMissingPartialKeyIsTreatedAsASingleReason() {
        let digest = CloudKitErrorDigest.make(from: ckError(.notAuthenticated))
        XCTAssertEqual(digest.reasons.count, 1)
        XCTAssertTrue(digest.userMessage.contains("nicht bei iCloud angemeldet"))
    }

    func testNonCloudKitErrorFallsBackToItsOwnDescription() {
        let error = NSError(
            domain: "NSCocoaErrorDomain",
            code: 134060,
            userInfo: [NSLocalizedDescriptionKey: "Der Speicher konnte nicht geöffnet werden."]
        )
        let digest = CloudKitErrorDigest.make(from: error)

        XCTAssertEqual(digest.topDomain, "NSCocoaErrorDomain")
        XCTAssertEqual(digest.reasons.count, 1)
        XCTAssertFalse(digest.reasons[0].isCloudKit)
        XCTAssertEqual(digest.userMessage, "Der Speicher konnte nicht geöffnet werden.")
        // No CKError case name may be invented for a foreign domain.
        XCTAssertFalse(digest.diagnosticLines.joined().contains("("))
    }

    func testAForeignErrorNestedInsideAPartialFailureIsKept() {
        let digest = CloudKitErrorDigest.make(from: error([
            recordID("D1"): NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [
                NSLocalizedDescriptionKey: "Keine Internetverbindung."
            ])
        ]))
        XCTAssertEqual(digest.reasons.count, 1)
        XCTAssertEqual(digest.reasons[0].domain, NSURLErrorDomain)
        XCTAssertEqual(digest.userMessage, "Keine Internetverbindung.")
    }

    // MARK: - Report shape

    func testDiagnosticLinesNameTheCodeTheServerTextAndTheRecords() {
        let digest = CloudKitErrorDigest.make(from: error([
            recordID("REC-0000000001"): ckError(.limitExceeded, server: "record size 1.4MB exceeds limit"),
        ]))
        let text = digest.diagnosticLines.joined(separator: "\n")

        XCTAssertTrue(text.contains("partialFailure"), "the outer code is still stated")
        XCTAssertTrue(text.contains("limitExceeded"))
        XCTAssertTrue(text.contains("record size 1.4MB exceeds limit"))
        XCTAssertTrue(text.contains("REC-0000000001"))
    }

    func testItemLabelsUseTheRecordNameNotThePointerDescription() {
        let label = CloudKitErrorDigest.itemLabel(AnyHashable(recordID("ABCDEF")))
        XCTAssertEqual(label, "ABCDEF")
        XCTAssertEqual(
            CloudKitErrorDigest.itemLabel(AnyHashable(CKRecordZone.ID(zoneName: "z1", ownerName: CKCurrentUserDefaultName))),
            "z1"
        )
    }

    func testTheSameFailureDigestsIdenticallyEveryTime() {
        // Dictionary iteration order is not stable across runs; a report that
        // reorders itself is a report two people cannot compare.
        func build() -> [String] {
            CloudKitErrorDigest.make(from: error([
                recordID("A"): ckError(.quotaExceeded),
                recordID("B"): ckError(.limitExceeded),
                recordID("C"): ckError(.serverRecordChanged),
            ])).diagnosticLines
        }
        for _ in 0..<20 { XCTAssertEqual(build(), build()) }
    }

    func testEveryKnownCloudKitCodeProducesGermanProseWithoutARawNumber() {
        let codes: [CKError.Code] = [
            .internalError, .partialFailure, .networkUnavailable, .networkFailure,
            .badContainer, .serviceUnavailable, .requestRateLimited, .missingEntitlement,
            .notAuthenticated, .permissionFailure, .unknownItem, .invalidArguments,
            .serverRecordChanged, .serverRejectedRequest, .assetFileNotFound,
            .assetFileModified, .incompatibleVersion, .constraintViolation,
            .operationCancelled, .changeTokenExpired, .batchRequestFailed, .zoneBusy,
            .badDatabase, .quotaExceeded, .zoneNotFound, .limitExceeded,
            .userDeletedZone, .managedAccountRestricted, .serverResponseLost,
            .assetNotAvailable, .accountTemporarilyUnavailable,
        ]
        for code in codes {
            let digest = CloudKitErrorDigest.make(from: ckError(code))
            let message = digest.userMessage
            XCTAssertFalse(message.isEmpty, "\(code.rawValue) produced nothing")
            XCTAssertFalse(
                message.contains("CKErrorDomain-Fehler"),
                "\(CloudKitErrorDigest.codeName(code)) leaked the raw CloudKit string"
            )
            XCTAssertGreaterThan(message.count, 30, "\(CloudKitErrorDigest.codeName(code)) is not a sentence")
        }
    }
}
