# App Store readiness

State as of 2026-08-01. Everything under "Done" was verified, not assumed —
the method is noted so it can be re-run.

## Done

| Item | How it was verified |
|---|---|
| Privacy manifest complete | `PrivacyInfo.xcprivacy` declares UserDefaults (CA92.1) **and** FileTimestamp (C617.1). The app reads file timestamps in `MediaStore` and `DiagnosticsRecorder`; an undeclared required-reason API is rejected on upload as ITMS-91053. |
| Manifest actually ships | `ls AIApp.app` in the built bundle |
| No debug seams in Release | Release build, then `strings -a AIApp.app/AIApp` for all eight `AIITY_*` / `PROVIDER_SETTINGS_JSON` / `AIITY_TEST_API_KEY` hooks — all absent. This caught `PROVIDER_SETTINGS_JSON`, which was **not** DEBUG-gated and shipped a way to redirect the app's API base URL. |
| Extension version matches the app | Both now `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`. A hardcoded 1.0 against an app at 0.6.0 is ITMS-90473. |
| App icon present | 1024pt `icon_1024.png` in `AppIcon.appiconset`, present in the built bundle |
| Privacy policy URL | <https://aiity.de/privacy> (English, for App Store Connect) and <https://aiity.de/datenschutz> (German) — both live |
| Export compliance declared | `ITSAppUsesNonExemptEncryption: false` in the built Info.plist |
| Release configuration builds | `xcodebuild -configuration Release -destination generic/platform=iOS` |
| Blockers / races | Adversarial audit, 19 confirmed findings — **all 19 fixed** (`8973b60` + `HEAD`), each with a regression test |

## Needs you — cannot be done from here

1. **Impressum and the DSGVO "Verantwortlicher"**. Both pages carry visible
   `[PLACEHOLDER]` fields for name, address and email. An Impressum is legally
   required for a site operated from Germany (§ 5 DDG) and the details were
   deliberately not invented. Edit `web/static/impressum/index.html` and
   section 1 of both `web/static/datenschutz/index.html` (German) and
   `web/static/privacy/index.html` (English), then rebuild and redeploy — see
   `web/README.md`.

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

**Guideline 1.2 — user-generated content.** The app shows model output the
user prompted for. There is currently **no report/block path**. If review
treats agent output as UGC, that is the gap they will name, and it is now the
single largest known submission risk. Cheap insurance: a "Diesen Inhalt melden"
action on a message.

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

- Localisation: German only (`CFBundleDevelopmentRegion: de`). Fine to ship,
  but it caps the audience.
- The Live Activity extension has no `PrivacyInfo.xcprivacy`. Not required
  today because it uses no required-reason API — recheck if that changes.
