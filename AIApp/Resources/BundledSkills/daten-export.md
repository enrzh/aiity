---
name: daten-export
description: Daten-Export & Backup für Mini-Apps — CSV/JSON-Export, Kopieren in die Zwischenablage, Import per Einfügen, versionierte Backups mit Wiederherstellung.
version: 1.0.0
---

# Daten-Export & Backup (Mini-Apps)

Use when a mini-app lets the user get data OUT (export, copy, backup) or back IN (paste-import, restore). No file downloads, no share sheet — the reliable exit is text: render it, let the user copy it.

## Sandbox facts

- Storage: only `await miniapp.storage.get(key)` / `set(key, value)` (JSON, `null` when missing), no key listing — keep ALL state under ONE root key (e.g. `state`) or export cannot find it. Small preferences-style store: prune old backups, no blobs.
- `<a download>`, `data:`/`blob:` loads and `window.open` are cancelled silently — never build download links. No `navigator.share`; camera/mic denied.

## Export

Serialize into an envelope so imports can be validated:

```js
const payload = { app: "habit-tracker", schemaVersion: 1,
  exportedAt: new Date().toISOString(), data: state };
```

Show it AND copy it. Clipboard needs a user gesture; keep the visible fallback:

```js
ta.value = text; ta.hidden = false;   // visible fallback, always
try { await navigator.clipboard.writeText(text); miniapp.haptic(); }
catch { ta.focus(); ta.select(); document.execCommand('copy'); }
```

CSV for German spreadsheets: SEMICOLON delimiter, quote fields with `;`, `"` or newlines (double inner quotes), German headers, de-DE numbers, dates DD.MM.YYYY. JSON stays machine-readable: raw numbers, ISO 8601 dates.

## Import (paste)

`<textarea>` plus "Einfügen & Importieren" button. Never trust pasted text:

```js
let p; try { p = JSON.parse(text); } catch { return err("Kein gültiges JSON."); }
if (p?.schemaVersion !== 1 || !Array.isArray(p?.data?.items)) return err("Format nicht erkannt.");
const items = p.data.items.filter(isValidItem).map(sanitizeItem);
```

Preview plus explicit confirm ("12 Einträge, Export vom 07.08.2026 — Ersetzen oder Zusammenführen?"); snapshot current state into a backup slot BEFORE overwriting (undoable import); success: `miniapp.haptic()` plus summary, failure: specific German error, never a silent no-op.

## Versioned backups

Keys `backup:1`…`backup:3` plus `backupIndex` (`{slot, savedAt, count}`); keep 3, overwrite oldest. Restore: list slots → confirm → snapshot current state first → apply → haptic. Check `schemaVersion` on load/import; migrate stepwise, never drop unknown fields.

## Backup reminder (one-shot only)

Notifications fire exactly ONCE — no repeating triggers. Offer "In 7 Tagen erinnern"; schedule only the next occurrence and reschedule on the user's next action (see termine-erinnerungen):

```js
const r = await miniapp.notify("Backup", "Zeit für ein Backup deiner Daten.", 7 * 24 * 3600);
if (r.ok === false) disableReminderQuietly();   // e.g. "permission_denied"
```

Only after a user tap, never on app start; never re-request after a denial — degrade to an in-app hint.

## UI conventions

German labels ("Exportieren", "Kopieren", "Backup erstellen", "Wiederherstellen"), 44px touch targets, an empty state, destructive actions behind a confirm.
