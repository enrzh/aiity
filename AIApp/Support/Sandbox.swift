import Foundation

/// Hardens generated mini-app HTML before it enters the runner web view.
/// CSP depends on declared capability (offline / network / browser).
enum Sandbox {
    static func harden(_ html: String, capability: MiniAppCapability = .offline) -> String {
        let csp = capability.csp
        let injection = """
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="aiity-capability" content="\(capability.rawValue)">
        <script>\(bridgeScript)</script>
        """
        if let headRange = html.range(of: "<head>", options: .caseInsensitive) {
            var hardened = html
            hardened.insert(contentsOf: injection, at: headRange.upperBound)
            return hardened
        }
        return "<!doctype html><html><head>\(injection)</head><body>\(html)</body></html>"
    }

    /// Promise-based bridge: storage, haptics, notify, health, openExternal.
    static let bridgeScript = """
    (function () {
      let nextCallId = 1;
      const pending = new Map();
      function call(action, payload) {
        return new Promise((resolve) => {
          const id = nextCallId++;
          pending.set(id, resolve);
          window.webkit.messageHandlers.bridge.postMessage({ id, action, payload: payload || {} });
        });
      }
      window.miniapp = {
        storage: {
          get: (key) => call('storage.get', { key }),
          set: (key, value) => call('storage.set', { key, value }),
        },
        haptic: () => { call('haptic', {}); },
        notify: (title, body, inSeconds) => call('notify.schedule', { title, body, inSeconds }),
        health: {
          query: (type, days) => call('health.query', { type, days }),
        },
        /** Open a URL in Safari. Prompts the user for confirmation first; the
            returned {ok} reflects whether they allowed it. Use for external links. */
        openExternal: (url) => call('open.external', { url }),
        capability: document.querySelector('meta[name="aiity-capability"]')?.content || 'offline',
        _resolve: (id, value) => {
          const resolver = pending.get(id);
          if (resolver) { pending.delete(id); resolver(value); }
        },
      };
    })();
    """
}
