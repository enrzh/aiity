# App Store readiness

State as of 2026-08-01. Everything under "Done" was verified, not assumed —
the method is noted so it can be re-run.

## Done

| Item | How it was verified |
|---|---|
| Privacy manifest complete | `PrivacyInfo.xcprivacy` declares UserDefaults (CA92.1) **and** FileTimestamp (C617.1). The app reads file timestamps in `MediaStore` and `DiagnosticsRecorder`; an undeclared required-reason API is rejected on upload as ITMS-91053. |
| Manifest actually ships | `ls AIApp.app` in the built bundle |
| No debug seams in Release | Release build, then `strings -a AIApp.app/AIApp` for all eight `AIITY_*` / `PROVIDER_SETTINGS_JSON` / `AIITY_TEST_API_KEY` hooks — all absent. This caught `PROVIDER_SETTINGS_JSON`, which was **not** DEBUG-gated and shipped a way to redirect the app's API base URL. |
| Extension version matches the app | Both now `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`, single-sourced from the build settings — verified by reading `CFBundleShortVersionString` out of both built plists. A version hardcoded in either plist drifts from the other and is rejected as ITMS-90473. |
| App icon present | 1024pt `icon_1024.png` in `AppIcon.appiconset`, present in the built bundle |
| Privacy policy URL | <https://aiity.de/privacy> (English, for App Store Connect) and <https://aiity.de/datenschutz> (German) — both live |
| Export compliance declared | `ITSAppUsesNonExemptEncryption: false` in the built Info.plist |
| Release configuration builds | `xcodebuild -configuration Release -destination generic/platform=iOS` |
| Report path for model output | Guideline 1.2 — context menu on assistant messages, `ContentReportTests` pins what the report may contain |
| Blockers / races | Adversarial audit, 19 confirmed findings — **all 19 fixed** (`8973b60` + `HEAD`), each with a regression test |
| Version set for release | `1.0.0` (build `1`) in **both** bundles, read back out of the built `.app` and `.appex`. On a resubmission App Store Connect requires a higher build number: bump `CURRENT_PROJECT_VERSION`, not `MARKETING_VERSION`. |
| Ten languages ship | `CFBundleLocalizations` declares all ten and `AIApp/Localizable.xcstrings` has an entry per key. Verified by generating the store screenshots in each locale — a missing string shows up as German text in an English frame. |
| Unit tests | 276 tests, 0 failures. Check the **count**: a test file absent from `project.yml` never compiles and `xcodebuild` still exits 0. |

## Needs you — cannot be done from here

1. **Trader vs non-trader in App Store Connect.** This one is worth thinking
   about before you submit, because it decides whether Apple publishes your
   home address.

   Under the EU Digital Services Act, Apple asks every developer distributing
   in the EU to declare trader status, and it publishes the **trader's** name,
   address, phone and email on the listing. A **non-trader** declaration does
   not get published that way. aiity is a free app by a private individual with
   no revenue and no company, which is the ordinary non-trader case — but the
   test is whether you act "for purposes relating to trade, business, craft or
   profession", so the moment you add a paid tier or ads, it flips to trader
   and the address goes public. Declare honestly; Apple can ask for evidence
   and will remove apps over a wrong declaration.

   Either way the **website Impressum stays** — § 5 DDG applies to
   *geschäftsmäßige* telemedia, which is read broadly enough to cover a landing
   page for a published app even without revenue.

2. **App Store Connect metadata** — app name, subtitle, keywords, description,
   support URL, category, age rating. Screenshots for every required device
   size. None of this can be filled in without your account.

3. **Apple's App Privacy questionnaire.** The honest answers are "no data
   collected" and "no tracking", matching the manifest — but you have to submit
   them yourself.

## Review risks worth knowing before you submit

**Guideline 2.5.2 — executable code.** Mini-apps are generated HTML/JS running
in a `WKWebView`. That is explicitly permitted: the rule allows downloaded
scripts and code as long as they run in the WebKit framework and do not change
the app's primary purpose. Nothing here executes code outside WebKit. This
should pass, but expect it to be looked at.

**Guideline 1.2 — user-generated content.** Addressed. Long-pressing any
assistant message offers "Inhalt melden": pick a reason, add an optional note,
**see the exact text that will be sent**, then send it by mail to
`getaiityapp@gmail.com` (or copy it). Only that one message goes — not the
conversation, not your keys, not the diagnostics record — and a test asserts
that. Both privacy policies describe it.

Reports go to `getaiityapp@gmail.com`. **Read that mailbox** — 1.2 asks for a
way to report *and* for responses to those reports, and an unattended address
is a rejection risk on the second submission rather than the first. The address
is a single constant in `AIApp/Services/ContentReport.swift`, and it also
appears in the Impressum and both privacy policies.

**Metadata positioning.** In the app, "build the tool you need instead of
installing another app" is a fine idea. In App Store *metadata*, phrasing it as
"you don't need the App Store anymore" invites rejection. The website says
"Kein App Store, keine Installation, kein Konto" — that is fine on your own
site; do not carry that line into the listing.

**`NSAllowsArbitraryLoads: true`.** Justified — users point the app at their own
LAN/Tailscale gateways over http, and ATS honours no exception for raw IP
literals. Be ready to say exactly that. The existing comment in `project.yml`
is the explanation.

**Age rating.** The app talks to third-party models whose output is not
filtered by you. Rate honestly rather than 4+.

## Not blocking, but next

- App Store Connect wants localised metadata per language. The app itself now
  ships ten (`CFBundleLocalizations`), so the listing can too — but each
  locale's description, keywords and screenshots are a separate entry there,
  and an English-only listing for a ten-language app is a wasted advantage
  rather than a rejection risk.
- The Live Activity extension has no `PrivacyInfo.xcprivacy`. Not required
  today because it uses no required-reason API — recheck if that changes.
