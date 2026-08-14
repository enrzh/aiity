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

    /// Promise-based bridge: the legacy `window.miniapp` surface (storage,
    /// haptics, notify, openExternal) plus the documented `window.aiity`
    /// surface below. Served natively by `MiniAppRunnerView.Coordinator` and
    /// only while the trusted, CSP-hardened document is showing — a remote
    /// document (browser tier) never gets this script or the handler.
    ///
    /// # `window.aiity` — JS API contract (v1)
    ///
    /// All calls are async and promise-based. A failure REJECTS with an
    /// `Error` whose `message` (and `code`) is one of the codes below — unlike
    /// `window.miniapp`, which resolves `{ok:false}` shapes.
    ///
    /// `aiity.storage` — durable per-app key-value storage. No consent prompt
    /// (it is the app's own data, on this device only), persisted across app
    /// restarts and mini-app reloads, wiped when the mini-app is deleted.
    /// String keys and values only; 1 MB total per app.
    ///  * `getItem(key) -> Promise<string|null>`
    ///  * `setItem(key, value) -> Promise<null>` — rejects `quota_exceeded`
    ///    when the write would push the app over 1 MB (existing data stays).
    ///  * `removeItem(key) -> Promise<null>`
    ///  * common rejection: `invalid_argument` (non-string key/value).
    ///
    /// `aiity.notifications` — local notifications, consent-gated: the FIRST
    /// `schedule` call shows a native per-app consent prompt (plus the OS
    /// permission dialog on very first granted use). Tapping a delivered
    /// notification reopens this mini-app.
    ///  * `schedule({title, body, at}) -> Promise<{id}>` — `at` is epoch
    ///    milliseconds or an ISO 8601 string and must be in the future; at
    ///    most 8 pending per app. Rejects `consent_denied` (user declined the
    ///    aiity prompt), `permission_denied` (OS authorization missing),
    ///    `invalid_date`, `date_in_past`, `limit_exceeded`.
    ///  * `cancelAll() -> Promise<{cancelled}>` — never prompts.
    ///
    /// When this contract changes, the mini-app generation system prompt
    /// (`AgentLoop.buildSystemPrompt`, which advertises `miniapp.*` today)
    /// must be updated to match — deliberately not done from here.
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
      /* window.aiity calls reject on failure; the native side always answers
         {ok, value?, error?} for them, and this unwraps it. */
      function request(action, payload) {
        return call(action, payload).then((r) => {
          if (r && r.ok === true) { return r.value === undefined ? null : r.value; }
          const code = (r && r.error) || 'bridge_error';
          const error = new Error(code);
          error.code = code;
          throw error;
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
      window.aiity = {
        storage: {
          getItem: (key) => request('storage.getItem', { key }),
          setItem: (key, value) => request('storage.setItem', { key, value }),
          removeItem: (key) => request('storage.removeItem', { key }),
        },
        notifications: {
          schedule: (options) => request('notifications.schedule', options || {}),
          cancelAll: () => request('notifications.cancelAll', {}),
        },
      };
    })();
    """
}
