import Foundation
import UIKit
import UniformTypeIdentifiers

/// Reads **plain text only** from the system pasteboard.
///
/// Avoids a common iOS bug: rich copy (Safari/Notes) yields RTFD item paths like
/// `…/shared-pasteboard/items/…/….rtfd` instead of the visible string. Those paths
/// must never be submitted as OAuth codes, skill URLs, or chat input.
enum PlainPasteboard {

    /// Best-effort plain string from the pasteboard, or nil if unusable.
    static func plainText() -> String? {
        let pb = UIPasteboard.general

        // 1) Preferred API
        if let s = pb.string, let clean = sanitize(s) { return clean }

        // 2) Multiple strings
        if let many = pb.strings {
            for s in many {
                if let clean = sanitize(s) { return clean }
            }
        }

        // 3) Explicit plain-text types (skip file URLs / rtfd packages)
        let plainTypes = [
            UTType.utf8PlainText.identifier,
            UTType.plainText.identifier,
            "public.utf8-plain-text",
            "public.plain-text",
            "public.text",
        ]
        for type in plainTypes {
            if let data = pb.data(forPasteboardType: type),
               let s = String(data: data, encoding: .utf8),
               let clean = sanitize(s) {
                return clean
            }
            if let s = pb.value(forPasteboardType: type) as? String,
               let clean = sanitize(s) {
                return clean
            }
        }

        // 4) RTF → plain string (never use the .rtfd path)
        if let data = pb.data(forPasteboardType: UTType.rtf.identifier)
            ?? pb.data(forPasteboardType: "public.rtf") {
            if let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ), let clean = sanitize(attr.string) {
                return clean
            }
        }

        // 5) HTML → plain
        if let data = pb.data(forPasteboardType: UTType.html.identifier)
            ?? pb.data(forPasteboardType: "public.html") {
            if let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            ), let clean = sanitize(attr.string) {
                return clean
            }
        }

        return nil
    }

    /// Sanitize text already in a field (e.g. after system paste into TextField).
    /// Returns empty string if the value looks like a pasteboard file path dump.
    static func sanitize(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // Zero-width / BOM junk from rich editors
        t = t
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if looksLikePasteboardArtifact(t) { return nil }

        // If multi-line garbage mixed with a good code= URL, prefer that line
        if t.contains("\n"), t.count > 200 {
            for line in t.components(separatedBy: .newlines) {
                let L = line.trimmingCharacters(in: .whitespaces)
                if looksLikePasteboardArtifact(L) { continue }
                if L.contains("code=") || L.hasPrefix("http") || L.count > 8 {
                    if let one = sanitize(L) { return one }
                }
            }
        }

        return t.isEmpty ? nil : t
    }

    /// True for shared-pasteboard RTFD paths and similar non-user content.
    static func looksLikePasteboardArtifact(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.contains("shared-pasteboard") { return true }
        if lower.contains("useractivityd") { return true }
        if lower.contains("group.com.apple.coreservices") { return true }
        if lower.contains(".rtfd") { return true }
        if lower.contains(".rtf/") || lower.hasSuffix(".rtf") && lower.contains("/library/") { return true }
        if lower.contains("group containers") { return true }
        // Absolute path that looks like a pasteboard item, not a user path of interest
        if (lower.hasPrefix("/users/") || lower.hasPrefix("/private/") || lower.hasPrefix("file://"))
            && (lower.contains("/library/") || lower.contains("pasteboard") || lower.contains(".rtfd")) {
            return true
        }
        // UUID-looking folder dumps from pasteboard items
        if lower.contains("/items/") && lower.contains("-") && lower.count > 80
            && (lower.contains("pasteboard") || lower.contains("coreservices")) {
            return true
        }
        return false
    }
}
