---
name: formulare-tracker
description: "Formular- und Tracker-Mini-Apps: Inline-Validierung, deutsche Zahlen- und Datumsformate, Speichern bei jeder Eingabe, Rückgängig nach dem Löschen."
version: 1.0.0
---

# Formulare & Tracker Pro

Patterns for CRUD/tracker mini-apps. Prefer the `list-form`, `tracker`, `todo` templates; offline — default capability, no capability comment.

## State and persistence

- One state object, one key; `miniapp.storage.get` resolves to `null` — default it:
  `const state = (await miniapp.storage.get('state')) ?? { records: [], draft: {} };`
- Persist on EVERY change, per keystroke included (`input` → save draft; add/edit/delete → save records); never batch behind submit. A half-typed form must survive close/reopen: restore `state.draft` on load.
- JSON values only: store ISO strings, not `Date`s.
- Ids: `Date.now().toString(36) + Math.random().toString(36).slice(2, 8)` — no `crypto.randomUUID()` (null-origin sandbox).
- Day-keyed trackers: key by ISO `YYYY-MM-DD` (= `<input type="date">.value`) — sorts chronologically; German only for display.

## German formats

Everything the user SEES is German:

```js
const eur = new Intl.NumberFormat('de-DE', { style: 'currency', currency: 'EUR' }); // "1.234,56 €"
const dateDE = iso => new Date(iso).toLocaleDateString('de-DE',
  { day: '2-digit', month: '2-digit', year: 'numeric' }); // "07.08.2026"
```

## Comma-decimal input

Never `type="number"` for decimals — it fights comma input. Use `<input type="text" inputmode="decimal" placeholder="0,00">` + a tolerant parser (thousands-dots stripped only when a comma is present: "12.50" stays 12.5):

```js
function parseDE(s) {
  s = s.trim().replace(/[\s€]/g, '');
  if (s.includes(',')) s = s.replace(/\./g, '').replace(',', '.');
  const n = Number(s);
  return Number.isFinite(n) ? n : null; // null → inline error
}
```

## Field attributes

Counts: `inputmode="numeric"`; `tel`/`email` types + matching `autocomplete` (email adds `autocapitalize="off"`; domain fields `autocomplete="off"`). `enterkeyhint` next/done/go. Inputs `font-size: 16px`+ or iOS auto-zooms. `<input type="date">` = native German picker; display via `dateDE`.

## Inline validation

Validate on blur and submit, not per keystroke; clear errors once valid. German message under the field ("Bitte einen Betrag eingeben"), `aria-invalid="true"` + red border. On submit errors: focus the first invalid field, `miniapp.haptic()`, keep valid values. No `alert()`/`confirm()` — inline messages and toasts only.

## Delete with undo

No confirmation dialogs — delete immediately (keep record + index), save, render, `miniapp.haptic()`; toast above the bottom safe area (~5 s): "Eintrag gelöscht" + "Rückgängig" that splices it back at its old index. Persist after delete AND undo.

## Reminders and sensors

`miniapp.notify` only on a user tap of an explicit "Erinnern" control — never on load or automatically; on `permission_denied`: one calm inline note, disable the control, remember it, never re-request (full policy in termine-erinnerungen). Camera/mic/motion are denied by policy (`NotAllowedError`) — no photo/voice/shake features; offer a text alternative.
