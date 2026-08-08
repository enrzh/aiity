---
name: geld-prozent
description: Cent-genaue Geldrechnung mit deutschen Formaten – MwSt. 19 %/7 %, Prozente, Rabatt, Trinkgeld und Rechnungen fair teilen.
version: 1.0.0
---

# Geld & Prozent

For every mini-app that handles money or percentages:

- Compute in integer cents, never floats (0.1+0.2 !== 0.3). Convert once at input with a comma-aware parser (same as formulare-tracker's parseDE): strip thousands-dots ONLY if the string contains a comma, so "1.234,56" → 123456 cents and a dot-decimal "12.50" → 1250 cents. `s=s.trim().replace(/[\s€]/g,""); if(s.includes(",")) s=s.replace(/\./g,"").replace(",","."); const n=Number(s); const cents=Number.isFinite(n)?Math.round(n*100):null;` — never strip dots unconditionally.
- Output only via `new Intl.NumberFormat("de-DE",{style:"currency",currency:"EUR"}).format(cents/100)` → "1.234,56 €". Dates as DD.MM.YYYY (`toLocaleDateString("de-DE")`). Never hand-build number strings.
- Percentages: always from the original amount, `Math.round(cents*pct/100)` (kaufmännisches Runden). Never chain rounded intermediates.
- MwSt.: 19 % standard, 7 % reduced (Lebensmittel, Bücher). From gross: `net = Math.round(gross/1.19)`, `tax = gross - net`. Show Netto / MwSt. / Brutto separately.
- Split n ways without losing cents: `base = Math.floor(total/n)`, first `total % n` shares get one extra cent — shares MUST sum to the total. Same idea for spreading a discount across items.
- Tip: preset 5/10/15 % buttons plus custom field, computed in cents on the bill; per-person amounts when combined with a split.
- Validate inline: reject NaN, negatives, zero people. Persist state with `await miniapp.storage.set(key, value)` / `await miniapp.storage.get(key)`; `miniapp.haptic()` on calculate/add.
