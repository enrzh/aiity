import Foundation

/// Hardens generated mini-app HTML before it enters the runner web view.
/// CSP depends on declared capability (offline / network / browser).
enum Sandbox {
    static func harden(_ html: String, capability: MiniAppCapability = .offline,
                       allowedHosts: [String] = []) -> String {
        let csp = capability.csp(allowedHosts: Set(allowedHosts))
        let injection = """
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="aiity-capability" content="\(capability.rawValue)">
        <script>\(bridgeScript)</script>
        """
        // Never splice into model-authored markup.
        //
        // This used to insert after the first literal "<head>" anywhere in the
        // document. Mini-apps routinely begin with comments the app itself asks
        // for (`<!-- emoji: … -->`, `<!-- capability: … -->`), so a document
        // whose leading comment merely CONTAINS the text `<head>` — which a
        // model steered by a fetched page can arrange — swallowed the whole
        // injection into that comment. The result was a mini-app with no CSP
        // and no bridge script at all, and since NSAllowsArbitraryLoads is on
        // app-wide, that is unrestricted network access from generated code.
        //
        // Own the head instead: emit our own document whose <head> starts with
        // the policy, and put the model's markup after it. A second <head> or a
        // later <meta> cannot loosen a CSP that is already in force — the first
        // policy wins and additional ones can only intersect.
        return "<!doctype html>\n<html>\n<head>\(injection)</head>\n<body>\n\(html)\n</body>\n</html>"
    }

    /// Promise-based bridge: storage, haptics, notify, openExternal.
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
