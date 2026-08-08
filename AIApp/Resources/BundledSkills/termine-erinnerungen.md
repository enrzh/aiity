---
name: termine-erinnerungen
description: Termine & Erinnerungen — zeitumstellungssichere Datumslogik ohne Bibliotheken, Serien, Streaks und lokale Benachrichtigungen für Mini-Apps.
version: 1.0.0
---

# Termine & Erinnerungen

Apply whenever a mini-app handles dates, recurring events, habits/streaks, countdowns or reminders. Load state on start, save on every change (`miniapp.storage.get/set`); `miniapp.haptic()` on complete/save/schedule.

## Date math — no libraries, plain `Date`/`Intl` only

- LOCAL day keys (`"2026-08-07"`) from `getFullYear`/`getMonth()+1`/`getDate` with `padStart(2,'0')` — never `toISOString()`, whose UTC shift moves entries to the wrong day near midnight.
- Day steps survive DST via calendar arithmetic, never +86400000 ms: `const addDays=(d,n)=>new Date(d.getFullYear(),d.getMonth(),d.getDate()+n)`.
- Day diff: local midnights (`new Date(y,m,d)` both), then `Math.round((b-a)/86400000)`.
- Persist day keys or epoch ms; parse a day key with `new Date(y,m-1,d)` — `new Date("YYYY-MM-DD")` parses as UTC and shifts the day.

## Recurrence

- Weekly: store weekdays as `getDay()` numbers (0 = Sunday). Next occurrence of `w`: `addDays(today,(w-today.getDay()+7)%7||7)` — drop `||7` if today may count.
- Monthly: clamp against month overflow (Jan 31 + 1 month = Mar 3): `const addMonths=(d,n)=>{const y=d.getFullYear(),m=d.getMonth()+n; return new Date(y,m,Math.min(d.getDate(),new Date(y,m+1,0).getDate()))}`.
- Persist the RULE, compute the next occurrence on demand — never store expanded future dates.

## Streaks & habits

Completions as `{[dayKey]:true}` in storage. Streak: walk back day by day, starting yesterday if today is unfinished so it does not break the streak. Weeks start Monday — Mon–Sun grids.

## German output

UI text and formats are German: `toLocale(Date|Time)String('de-DE')` (DD.MM.YYYY, 24h); relative labels ("Heute", "Morgen", "in 3 Tagen") from day-key differences.

## Reminders (`miniapp.notify`)

`await miniapp.notify(title, body, inSeconds)` → `{ok:true, id}` or `{ok:false, error:"permission_denied"|"…"}`.

- One-shot, `inSeconds` ≥ 1 from now; target time → `Math.max(1, Math.round((target - Date.now())/1000))`. Title caps at 80 chars, body at 300.
- No repeating notifications: schedule ONLY the next occurrence; when the user next acts on the item, schedule the following one.

POLICY (mandatory):

- Call `miniapp.notify` ONLY on a direct user action ("Erinnern" tapped, saved with reminder toggle on, habit completed) — never automatically on load/open.
- On `permission_denied`: item stays saved and usable; show a calm hint ("Benachrichtigungen deaktiviert — in iOS-Einstellungen aktivierbar"), persist the denial, stop calling notify until the user taps a reminder control again — never retry or re-trigger the dialog.
- Reminders are always optional — the app must work fully without permission.

## Hard limits

No Web `Notification`, service workers or background timers — the page stops when the app closes; only `miniapp.notify` outlives it. Camera/mic/motion are denied by WebView policy — catch `NotAllowedError`, hide the feature.
