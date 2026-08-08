---
name: web-wrapper
description: Webseiten und interne Tools als Mini-Apps einbinden – Login-Seiten per Vollnavigation, Quick-Link-Startseiten und Embeds mit dauerhafter Anmeldung.
version: 1.0.0
---

# Web Wrapper

When wrapping a website, build a `<!-- capability: browser -->` mini-app:
- One site: declare `<!-- open: https://site.example -->` — the runner loads that URL as the top-level document (private/LAN addresses are blocked; prefer https). Body = tiny fallback: an "Öffne site.example…" line, a tap link, `location.replace(url)`. This is the path for login/internal web apps; the user signs in on the real site.
- `<iframe>` only for embed-friendly pages (widgets, docs, players); login/internal sites block framing — navigate top-level instead of fighting it.
- Several URLs: a local home screen of large link cards (`<a href="https://…">`); a tap navigates the whole view. The `miniapp.*` bridge is disabled once a remote page loads — use `miniapp.storage.get/set` and `miniapp.notify` only while the home screen is showing; `await miniapp.openExternal(url)` opens a link in Safari (user confirms; returns {ok}).
- Sessions persist per app: the user stays logged in across reopens. Never build your own login form or collect credentials.
- Capture is DENIED by policy: camera/microphone/motion requests fail with NotAllowedError. Do not wrap capture-dependent sites (video calls, QR scanners, recorders); if capture is optional, say so and let the site degrade.
- Schedule `await miniapp.notify(title, body, inSeconds)` only on a user tap; on {ok:false, error:"permission_denied"} show an inline hint — never re-request, never auto-schedule on open.
