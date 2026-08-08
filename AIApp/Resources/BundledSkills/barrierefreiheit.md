---
name: barrierefreiheit
description: Macht jede generierte Mini-App standardmäßig barrierefrei — semantische Bedienelemente, VoiceOver-Labels, Kontrast, sichtbarer Fokus und reduzierte Bewegung.
version: 1.0.0
---

# Barrierefreiheit (Accessibility)

Apply these rules to every mini-app. Accessibility is part of the quality bar, not a feature the user must ask for — VoiceOver, keyboard focus, and reduced motion must work in every generated app.

## Semantic controls

- Use real elements: `<button>` for actions, `<a href>` for navigation, `<input>`/`<select>`/`<textarea>` with a visible `<label for>`. Never a clickable `<div>` or `<span>` — those are invisible to VoiceOver.
- Set `<html lang="de">` (or the app's output language) so VoiceOver uses the right voice.
- One `<h1>`, logical heading order below it; keep DOM order equal to reading order and never use positive `tabindex`.

## Touch targets and focus

- Touch targets at least 44px tall and wide (via `min-height`/`padding`).
- Visible focus ring: style `:focus-visible` with `outline: 2px solid var(--accent); outline-offset: 2px`. Never `outline: none` without a replacement.

## VoiceOver

- Icon-only buttons get an `aria-label` in the app's output language: `<button aria-label="Eintrag löschen">🗑</button>`. Decorative icons/emojis get `aria-hidden="true"`.
- Put dynamic results (totals, timer state, "Gespeichert", validation messages) in a persistent `aria-live="polite"` region and update its text content; use `role="alert"` only for errors. Do not recreate the region per update.
- Express toggle state with `aria-pressed`/`aria-expanded`/`aria-checked`, never with color alone.

## Contrast and color

- Text contrast at least 4.5:1 (3:1 for text ≥ 24px or ≥ 19px bold), interactive components at least 3:1 — verify in BOTH light and dark mode, since every app ships dark mode via CSS variables.
- Never encode meaning by color alone: pair red/green with an icon or text (error = message text, not just a red border).

## Motion and feedback

- Respect `@media (prefers-reduced-motion: reduce)`: inside it, set `animation: none` and `transition-duration: 0.01ms` for decorative motion. Essential state changes still happen, just without movement.
- `miniapp.haptic()` supplements visual/announced feedback on meaningful actions — never as the only signal.

## German output conventions

- Format numbers with `Intl.NumberFormat("de-DE")` (comma decimals: 1.234,56) and dates as DD.MM.YYYY; VoiceOver then announces them correctly in German. Keep `aria-label` and live-region text in the same language as the UI.

## Platform limits

- Mini-app WebViews DENY camera, microphone, and motion sensors by policy. Never build accessibility aids that depend on them (voice input, camera magnifier, shake gestures); such calls reject with `NotAllowedError` — catch it, keep the app working, and offer a text alternative.
- Call `await miniapp.notify(title, body, inSeconds)` only as the direct result of a user action (e.g. starting a timer) — never automatically on load. If it returns `{ok:false, error:"permission_denied"}`, show the state inline via the `aria-live` region instead; do not re-request or retry.
- Persist accessibility choices the app offers (e.g. a "Größere Schrift" toggle) with `await miniapp.storage.set(key, value)` and restore them on start with `await miniapp.storage.get(key)`.
