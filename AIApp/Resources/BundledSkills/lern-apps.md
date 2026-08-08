---
name: lern-apps
description: Karteikarten- und Quiz-Apps mit echter Spaced-Repetition-Logik, Tages-Stapel, Statistik und Import per Einfügen.
version: 1.0.0
---

For flashcard/quiz apps, implement real spaced repetition:
- Cards {front, back, ease:2.5, interval:0, due:0}; whole deck under ONE miniapp.storage key — load on start, save after every answer.
- Simplified SM-2 via four buttons — Nochmal: interval=0, ease=max(1.3, ease-0.2), card stays in today's queue; Schwer: interval=max(1, interval*1.2), ease-=0.15; Gut: interval = interval ? Math.round(interval*ease) : 1; Einfach: interval = interval ? Math.round(interval*ease*1.3) : 2, ease+=0.15. due = now + interval days.
- Study only cards with due ≤ now: front, tap to flip, rate; miniapp.haptic() per answer; empty queue shows "Fertig für heute" plus tomorrow's count.
- Stats: due today, total, learned (interval ≥ 21), success rate — numbers via Intl.NumberFormat("de-DE"), dates as DD.MM.YYYY.
- Import: paste textarea, one "front,back" per line (split at first comma, trim, skip empties/duplicates); confirm the imported count.
- Reminders only on an explicit button tap; if miniapp.notify(title, body, inSeconds) returns {ok:false, error:"permission_denied"}, hide the option — never re-ask, never auto-schedule on open.
- No voice/photo cards — the WebView denies camera and mic.
