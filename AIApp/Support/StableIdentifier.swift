import CryptoKit
import Foundation

/// Turns an arbitrary string identifier into a stable UUID.
///
/// Some system APIs demand a `UUID` where the app's own identifier is just a
/// string — `WKWebsiteDataStore(forIdentifier:)` is the one that matters here,
/// because it decides which mini-apps share a cookie jar. A mini-app opened
/// from a chat preview is keyed by a content hash, not a UUID, so it had no
/// real identifier to give and fell back to a single hardcoded one. Every such
/// app therefore shared one data store: log in to a site in one previewed
/// browser app and you were logged in inside an unrelated one.
///
/// Derived rather than random, so the same app maps to the same store across
/// launches — a random UUID would isolate apps correctly but lose the session
/// on every open, which is the feature browser mini-apps exist for.
enum StableIdentifier {

    /// Deterministic UUID for `value`, shaped as an RFC 4122 v5 (name-based,
    /// SHA-1-style) identifier. SHA-256 truncated to 16 bytes is used for the
    /// digest — the version/variant bits are what make it a well-formed UUID,
    /// not the hash choice.
    static func uuid(from value: String) -> UUID {
        var digest = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        // Version 5 (name-based) in the high nibble of byte 6.
        digest[6] = (digest[6] & 0x0F) | 0x50
        // RFC 4122 variant in the top bits of byte 8.
        digest[8] = (digest[8] & 0x3F) | 0x80
        let bytes = (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: bytes)
    }

    /// A UUID identifier for a value that may already be one.
    ///
    /// Real UUIDs pass through unchanged so existing stores keep their
    /// identity — deriving over them would orphan every saved app's session.
    static func uuid(fromPossibleUUID value: String) -> UUID {
        UUID(uuidString: value) ?? uuid(from: value)
    }
}
