---
name: api-apps
description: "Baut robuste Netzwerk-Mini-Apps: Lade-, Leer- und Fehlerzustände, Timeouts, Offline-Cache und sichere API-Key-Abfrage — ohne hartkodierte Schlüssel."
version: 1.0.0
---

# Building API-backed Mini-Apps Safely

Apply whenever a mini-app calls an external API (`<!-- capability: network -->`).

## Capability & CSP

`network` allows fetch/XHR plus images, fonts and media over **https only**. All JS/CSS still stay **inline** (CSP blocks CDNs); no `<iframe>` (needs `capability: browser`). `miniapp.capability` holds the current tier string.

## CORS reality check

Mini-apps run from a null origin: a fetch only succeeds if the API sends `Access-Control-Allow-Origin: *`. Public JSON APIs generally do; normal websites do not — never scrape a page via fetch (to SHOW a site, build a `browser` app). A CORS failure is a generic `TypeError`, indistinguishable from offline: one honest message for both ("Keine Verbindung oder API nicht erreichbar") + retry button, never auto-retry in a loop.

## The four UI states — mandatory

Every remote call drives exactly one visible state: **loading** (controls disabled), **success**, **empty** ("Keine Daten"-hint, not a blank area), **error** (plain message + "Erneut versuchen"). Never a dead screen or raw error object.

## Timeouts

`fetch` has no built-in timeout — always wrap it:

```js
async function apiFetch(url, opts = {}, ms = 10000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try {
    const res = await fetch(url, { ...opts, signal: ctrl.signal });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    return await res.json();
  } finally { clearTimeout(t); }
}
```

Distinguish HTTP errors (`401/403` → key problem, `429` → "Später erneut versuchen") from network/CORS/timeout failures.

## Offline cache (stale-while-revalidate)

Persist every success: `await miniapp.storage.set('cache:' + endpointKey, { data, fetchedAt: Date.now() })` — values must be JSON-serializable. On start read the cache (`get` resolves `null` if absent); if present, render it immediately with a timestamp line ("Stand: 07.08.2026, 14:32") and refresh in the background. On refresh failure keep the cached view with a subtle offline hint — not a blocking error.

## API keys — never hardcode

NEVER put a key/token literal into the HTML — not as a placeholder, not "for testing". If the API needs a key, ask once and store locally:

1. `const key = await miniapp.storage.get('apiKey');` — if `null`, show a setup view: one sentence of purpose, an input, a save button, a provider-key-page link via `miniapp.openExternal(…)` (`{ok:false}` = user declined — ignore).
2. Send the key only to that provider's https endpoint — never any other host.
3. Offer a settings row to change/remove it. On 401/403 return to the setup view with a "Schlüssel prüfen" hint — never silently delete the stored key.

## Also applies

- `miniapp.notify` only on a direct user tap, never automatically; on `permission_denied` quietly disable the reminder UI (see termine-erinnerungen).
- Camera/mic/motion are denied (`NotAllowedError`) — offer manual entry.
- German UI by default: `Intl.NumberFormat('de-DE')` (1.234,56 €), dates DD.MM.YYYY.
