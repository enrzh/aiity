import Foundation

/// Builds a browser-capability mini-app that opens a URL as a full in-app page —
/// deterministically, without the model (which tends to over-refuse "accessing"
/// a website). Used by the chat short-circuit and the Apps "+" web-app creator.
enum WebAppBuilder {

    /// Adds https:// when the user typed a bare host; leaves an explicit scheme.
    static func normalize(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return v }
        if !v.contains("://") { v = "https://" + v }
        return v
    }

    /// True when the user typed the scheme themselves. `normalize` cannot be
    /// asked afterwards — its output always has one — so the answer is recorded
    /// in the generated document (`schemeWasAssumed(in:)`) for the runner's
    /// one-shot http fallback: retrying over cleartext is only defensible for a
    /// scheme WE guessed, never for an https the user asked for.
    static func hasExplicitScheme(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).contains("://")
    }

    /// Marker emitted when https was our assumption rather than the user's choice.
    static let assumedSchemeMarker = "<!-- scheme: assumed -->"

    static func schemeWasAssumed(in html: String) -> Bool {
        html.range(of: #"<!--\s*scheme:\s*assumed\s*-->"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func host(of raw: String) -> String {
        URL(string: normalize(raw))?.host ?? raw
    }

    /// Full mini-app HTML: a tiny shell that top-level-navigates to the site
    /// (works for login/internal apps that block <iframe> embedding).
    static func html(urlString: String, name: String = "") -> String {
        let url = normalize(urlString)
        let h = URL(string: url)?.host ?? url
        let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? h : name
        let schemeNote = hasExplicitScheme(urlString) ? "" : "\n" + assumedSchemeMarker
        return """
        <!doctype html>
        <!-- emoji: 🌐 -->
        <!-- capability: browser -->
        <!-- open: \(url) -->\(schemeNote)
        <html lang="de"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(esc(title))</title>
        <style>:root{color-scheme:light dark}html,body{height:100%}body{margin:0;font-family:-apple-system,system-ui,sans-serif;display:flex;flex-direction:column;gap:14px;align-items:center;justify-content:center;color:#8a8a8e}a{color:#0a84ff}</style>
        </head><body>
        <p>Öffne \(esc(h))…</p>
        <a id="lnk" href="\(esc(url))">Antippen, falls es nicht automatisch lädt</a>
        <script>location.replace(\(jsString(url)));</script>
        </body></html>
        """
    }

    /// The site a browser mini-app exists to open, declared as `<!-- open: URL -->`.
    ///
    /// The runner loads this directly instead of rendering the shell below. The
    /// shell's own document has a null origin (loadHTMLString with no baseURL)
    /// AND a `default-src 'none'` CSP, so a script inside it cannot navigate to
    /// the site — it would have to escape its own policy. Loading the URL as the
    /// document sidesteps that entirely; the shell stays only as a fallback for
    /// older saved apps that have no marker.
    static func openTarget(in html: String) -> URL? {
        if let range = html.range(of: #"<!--\s*open:\s*([^\s>]+)\s*-->"#, options: .regularExpression) {
            let raw = String(html[range])
                .replacingOccurrences(of: "<!--", with: "")
                .replacingOccurrences(of: "-->", with: "")
                .replacingOccurrences(of: "open:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = webURL(raw) { return url }
            // A marker that names something we refuse to load (file:, data:)
            // must not fall through to the shell — the shell navigates to that
            // very URL. Treat the app as having no target at all.
            return nil
        }
        return legacyShellTarget(in: html)
    }

    /// Apps saved before the `<!-- open: -->` marker existed carry the target
    /// only inside the shell body. The shell itself can never navigate — null
    /// origin plus `default-src 'none'` — so without this it shows
    /// "Öffne host…" forever. Recover the URL and load it as the document, the
    /// same way a marker app is loaded.
    ///
    /// Deliberately keyed on the shell's own fingerprint (`<a id="lnk">`, or a
    /// tiny `location.replace` document). A rich browser mini-app that happens
    /// to call `location.replace` on a tap must keep rendering its own UI, not
    /// be silently replaced by whatever URL appears in its source.
    static func legacyShellTarget(in html: String) -> URL? {
        if let href = firstMatch(#"<a[^>]*id=["']lnk["'][^>]*href=["']([^"']+)["']"#, in: html),
           let url = webURL(href) {
            return url
        }
        guard html.count < 1500 else { return nil }
        if let raw = firstMatch(#"location\.replace\(\s*["']([^"']+)["']\s*\)"#, in: html),
           let url = webURL(raw) {
            return url
        }
        if let raw = firstMatch(#"location\.href\s*=\s*["']([^"']+)["']"#, in: html),
           let url = webURL(raw) {
            return url
        }
        return nil
    }

    /// First capture group of `pattern`, unescaped from HTML entities.
    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only http(s) may ever become a directly-loaded document.
    private static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Detects a bare "open a website" request so the chat can build the browser
    /// app without the model. Conservative: the message must be essentially just
    /// a URL/host, optionally wrapped in an open-verb / "als Browser-Mini-App".
    static func detectOpenRequest(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [String(localized: "öffne "), "oeffne ", "open ", "besuche ", "visit ", "lade ",
                        "ruf ", "rufe ", "zeig mir ", "zeige mir ", "zeige ", "go to ", "browse ", "gehe zu "]
        let lower = t.lowercased()
        for p in prefixes where lower.hasPrefix(p) {
            t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        let suffixes = [" als browser-mini-app", " als browser mini-app", " als browser-app",
                        " als mini-app", " als web-app", " als webapp", " im browser",
                        " als browser", " als app", String(localized: " öffnen"), " aufrufen"]
        var lower2 = t.lowercased()
        for s in suffixes where lower2.hasSuffix(s) {
            t = String(t.dropLast(s.count)).trimmingCharacters(in: .whitespaces)
            lower2 = t.lowercased()
        }
        return looksLikeURL(t) ? t : nil
    }

    static func looksLikeURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.contains(" "), t.count >= 4, t.count < 300 else { return false }
        if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") { return true }
        // Bare host: labels + an alphabetic TLD (>=2), optional path.
        let pattern = #"^[a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)*\.[a-z]{2,}(/\S*)?$"#
        return t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A JSON string literal is also a safe JS string literal.
    private static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(arr.dropFirst().dropLast())  // ["x"] -> "x"
    }
}
