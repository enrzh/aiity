---
name: web-wrapper
description: Webseiten und interne Tools als Mini-Apps einbinden – Login-Seiten per Vollnavigation, Quick-Link-Startseiten und Embeds mit dauerhafter Anmeldung.
version: 1.0.0
---

# Web Wrapper

When wrapping a website, build a `<!-- capability: browser -->` mini-app:
- One site: declare `<!-- open: https://site.example -->` — the runner loads that URL as the top-level document (private/LAN addresses are blocked; prefer https). Body = tiny fallback: an "Öffne site.example…" line, a tap link, `location.replace(url)`. This is the path for login/internal web apps; the user signs in on the real site.
- **Default to `<!-- open: … -->`, not `<iframe>`.** Framing is refused by the SERVER (`X-Frame-Options` / `frame-ancestors`) and nothing in the app can override it — an iframe that a site blocks renders as a blank box with no error. Use `<iframe>` only for pages you know are embed-friendly (widgets, docs, players); for anything else navigate the whole view.
- The runner behaves like a browser on the browser tier: popups (`window.open`, `target="_blank"`, OAuth sign-in windows) open in their own sheet and close themselves, `alert`/`confirm`/`prompt` show native dialogs, downloads and attachments land in the share sheet, `tel:`/`mailto:`/app-callback links ask before leaving, and the edge-swipe goes back. Do not reimplement any of that in the page.
- Some providers (Google sign-in among them) refuse OAuth inside an embedded view on purpose. The runner detects that and offers to finish the sign-in in Safari; do not try to work around it in the mini-app.
- Several URLs: a local home screen of large link cards (`<a href="https://…">`); a tap navigates the whole view. The `miniapp.*` bridge is disabled once a remote page loads — use `miniapp.storage.get/set` and `miniapp.notify` only while the home screen is showing; `await miniapp.openExternal(url)` opens a link in Safari (user confirms; returns {ok}).
- Sessions persist per app: the user stays logged in across reopens. Never build your own login form or collect credentials.
- Capture is DENIED by policy: camera/microphone/motion requests fail with NotAllowedError. Do not wrap capture-dependent sites (video calls, QR scanners, recorders); if capture is optional, say so and let the site degrade.
- Schedule `await miniapp.notify(title, body, inSeconds)` only on a user tap; on {ok:false, error:"permission_denied"} show an inline hint — never re-request, never auto-schedule on open.
