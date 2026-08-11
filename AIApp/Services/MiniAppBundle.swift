import Foundation

/// Multi-file mini-app payload: entry HTML plus optional companion files
/// (`app.js`, `style.css`, …). Bundled into one document for the sandbox runner.
struct MiniAppBundle: Equatable {
    var name: String
    var emoji: String
    var html: String
    /// Relative path → file body (no `..`).
    var files: [String: String]
    var iconSymbol: String? = nil

    var isMultiFile: Bool { !files.isEmpty }

    /// Single HTML the WKWebView can load (CSS/JS inlined).
    func bundledHTML() -> String {
        guard !files.isEmpty else { return html }
        var result = html
        let css = files
            .filter { $0.key.lowercased().hasSuffix(".css") }
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined(separator: "\n")
        if !css.isEmpty {
            let tag = "<style data-aiity-bundle=\"css\">\n\(css)\n</style>"
            if let range = result.range(of: "</head>", options: .caseInsensitive) {
                result.insert(contentsOf: tag, at: range.lowerBound)
            } else {
                result = tag + result
            }
        }
        let js = files
            .filter { $0.key.lowercased().hasSuffix(".js") }
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined(separator: "\n")
        if !js.isEmpty {
            let tag = "<script data-aiity-bundle=\"js\">\n\(js)\n</script>"
            if let range = result.range(of: "</body>", options: .caseInsensitive) {
                result.insert(contentsOf: tag, at: range.lowerBound)
            } else {
                result += tag
            }
        }
        let other = files.filter {
            let k = $0.key.lowercased()
            return !k.hasSuffix(".css") && !k.hasSuffix(".js") && !k.hasSuffix(".html")
        }
        if !other.isEmpty {
            // Neutralize "-->" inside a companion body: it would close the comment
            // early and let the remaining bytes become live DOM (script injection).
            let blob = other.sorted { $0.key < $1.key }
                .map { entry -> String in
                    // Both `-->` and the legacy `--!>` terminate an HTML comment,
                    // and a nested `<!--` can confuse parsers — neutralize all
                    // three so a companion body can never become live DOM.
                    func escape(_ s: String) -> String {
                        s.replacingOccurrences(of: "-->", with: "--&gt;")
                            .replacingOccurrences(of: "--!>", with: "--!&gt;")
                            .replacingOccurrences(of: "<!--", with: "&lt;!--")
                    }
                    return "<!-- file:\(escape(entry.key))\n\(escape(entry.value))\n-->"
                }
                .joined(separator: "\n")
            result += "\n" + blob
        }
        return result
    }

    func filesJSON() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: files, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    static func files(fromJSON json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return obj.reduce(into: [String: String]()) { result, entry in
            let path = MiniAppBundleParser.sanitizePath(entry.key)
            if !path.isEmpty { result[path] = entry.value }
        }
    }
}

enum MiniAppBundleParser {
    static func extract(from text: String) -> MiniAppBundle? {
        guard let html = extractHTMLFence(from: text) else { return nil }
        let meta = metaFromHTML(html)
        var files: [String: String] = [:]

        let pattern = #"```([a-zA-Z0-9_+-]+)(?::([^\n`]+))?\n([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return MiniAppBundle(
                name: meta.name, emoji: meta.emoji, html: html, files: [:], iconSymbol: meta.iconSymbol
            )
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            let lang = ns.substring(with: match.range(at: 1)).lowercased()
            let pathPart = match.range(at: 2).location != NSNotFound
                ? ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                : ""
            let body = ns.substring(with: match.range(at: 3))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if lang == "html" || lang == "htm" { continue }
            let path: String
            if !pathPart.isEmpty {
                path = sanitizePath(pathPart)
            } else if lang == "css" {
                path = "style.css"
            } else if lang == "js" || lang == "javascript" {
                path = "app.js"
            } else if lang == "file" {
                continue
            } else {
                path = sanitizePath("extra.\(lang)")
            }
            guard !path.isEmpty else { continue }
            files[path] = body
        }

        return MiniAppBundle(
            name: meta.name, emoji: meta.emoji, html: html, files: files, iconSymbol: meta.iconSymbol
        )
    }

    static func extractHTMLFence(from text: String) -> String? {
        // ```html … ``` (case-insensitive fence)
        let fenceMarkers = ["```html", "```HTML", "``` htm", "```htm"]
        var fenceStart: Range<String.Index>?
        for marker in fenceMarkers {
            if let r = text.range(of: marker, options: .caseInsensitive) {
                fenceStart = r
                break
            }
        }
        if let fenceStart {
            let after = fenceStart.upperBound
            // Skip optional newline after fence language tag
            var contentStart = after
            if text[contentStart...].hasPrefix("\n") {
                contentStart = text.index(after: contentStart)
            }
            if let fenceEnd = text.range(of: "```", range: contentStart..<text.endIndex) {
                let html = String(text[contentStart..<fenceEnd.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !html.isEmpty { return MiniAppValidator.prepareHTML(html) }
            } else {
                // Stream cut off before closing fence — still recover.
                let html = String(text[contentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if html.count > 40 { return MiniAppValidator.prepareHTML(html) }
            }
        }
        // Bare document without fence
        let lower = text.lowercased()
        if lower.contains("<!doctype html") || (lower.contains("<html") && lower.contains("<body")) {
            if let start = text.range(of: "<!DOCTYPE", options: .caseInsensitive)
                ?? text.range(of: "<html", options: .caseInsensitive) {
                let html = String(text[start.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if html.count > 40 { return MiniAppValidator.prepareHTML(html) }
            }
        }
        return nil
    }

    static func metaFromHTML(_ html: String) -> (name: String, emoji: String, iconSymbol: String?) {
        var name = "Mini-App"
        if let titleStart = html.range(of: "<title>", options: .caseInsensitive),
           let titleEnd = html.range(of: "</title>", options: .caseInsensitive, range: titleStart.upperBound..<html.endIndex) {
            let title = String(html[titleStart.upperBound..<titleEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { name = title }
        }
        var emoji = "✨"
        if let match = html.range(of: #"<!--\s*emoji:\s*(\S+)\s*-->"#, options: .regularExpression) {
            let comment = String(html[match])
            if let value = comment.components(separatedBy: "emoji:").last?
                .replacingOccurrences(of: "-->", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                emoji = String(value.prefix(4))
            }
        }
        var iconSymbol: String?
        if let match = html.range(of: #"<!--\s*icon:\s*([a-z0-9._-]+)\s*-->"#, options: [.regularExpression, .caseInsensitive]) {
            let comment = String(html[match])
            if let value = comment.lowercased().components(separatedBy: "icon:").last?
                .replacingOccurrences(of: "-->", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                iconSymbol = String(value.prefix(64))
            }
        }
        return (name, emoji, iconSymbol)
    }

    static func sanitizePath(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !p.contains("\\"),
              let components = URLComponents(string: p),
              components.scheme == nil,
              components.host == nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else { return "" }
        guard let decodedPath = components.path.removingPercentEncoding else { return "" }
        p = decodedPath
        let hasSchemePrefix = p.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression
        ) != nil
        guard !p.contains("\\"), !hasSchemePrefix else {
            return ""
        }
        while p.hasPrefix("./") { p.removeFirst(2) }
        guard !p.isEmpty, !p.hasPrefix("/"),
              !p.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." }) else {
            return ""
        }
        return String(p.prefix(120))
    }
}
