import Foundation

/// Hardens generated mini-app HTML before it enters the runner web view:
/// a strict CSP forbids every network request; the bridge script exposes the
/// only capabilities a mini-app has (persistent storage + haptics).
enum Sandbox {
    static let csp = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:;"

    static func harden(_ html: String) -> String {
        let injection = """
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <script>\(bridgeScript)</script>
        """
        if let headRange = html.range(of: "<head>", options: .caseInsensitive) {
            var hardened = html
            hardened.insert(contentsOf: injection, at: headRange.upperBound)
            return hardened
        }
        return "<!doctype html><html><head>\(injection)</head><body>\(html)</body></html>"
    }

    /// Promise-based bridge: calls go out via webkit.messageHandlers.bridge,
    /// replies come back through miniapp._resolve(callId, value).
    static let bridgeScript = """
    (function () {
      let nextCallId = 1;
      const pending = new Map();
      function call(action, payload) {
        return new Promise((resolve) => {
          const id = nextCallId++;
          pending.set(id, resolve);
          window.webkit.messageHandlers.bridge.postMessage({ id, action, payload });
        });
      }
      window.miniapp = {
        storage: {
          get: (key) => call('storage.get', { key }),
          set: (key, value) => call('storage.set', { key, value }),
        },
        haptic: () => { call('haptic', {}); },
        _resolve: (id, value) => {
          const resolver = pending.get(id);
          if (resolver) { pending.delete(id); resolver(value); }
        },
      };
    })();
    """
}
