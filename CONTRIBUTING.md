# Contributing

Issues and pull requests are welcome. This is a one-person project, so the
honest version: I read everything, I am slow, and I would rather have a small
PR that does one thing than a large one I have to reason about all at once.

## Before you open a PR

```bash
xcodegen generate      # after adding OR removing any file
xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:AIAppTests test
```

**Check the test count, not the exit code.** It should be 276 or more. A test
file that is not in `project.yml` does not run, and `xcodebuild` exits 0 while
it does not run — several tests in this repo's history passed for months
without ever having been compiled.

If you touched anything the UI tests cover, `tools/stub_llm_server.py 8555` has
to be running for `-only-testing:AIAppUITests`. No network is needed for either
suite.

## Three things that will bite you

They are in the [README](README.md#contributing) with the full reasoning, and
each cost real data or real hours:

1. Every persisted `Codable` type needs a **hand-written decoder** using
   `decodeIfPresent` — a synthesized decoder treats a defaulted property as
   *required*, so one new field makes every stored record fail to decode.
2. **Never let an unreadable file be read as empty and then overwritten.** Found
   in five separate places here. Quarantine the bytes; if that fails, disable
   writing rather than destroy the only copy.
3. **German text is the localization key**, and only through SwiftUI's
   `Text(…)` or an explicit `String(localized:)`. A plain `String` assignment
   silently never looks anything up. See [`docs/LOCALIZATION.md`](docs/LOCALIZATION.md).

New user-facing strings go in `AIApp/Localizable.xcstrings`. Adding the German
and English is enough — leave the other eight rather than guessing at a language
you do not speak; a wrong translation is worse than a missing one.

## Especially welcome

- **Bug reports with a diagnostics export.** Mehr → Diagnose → export. It
  contains the last run's breadcrumbs and how it ended, and it is designed to be
  safe to paste — no keys, no conversation contents.
- **A provider dialect.** `AIApp/Providers/` is one file per dialect; adding one
  should not require touching anything else. If it does, that is a bug in the
  seam and worth saying so.
- **Anything in the sandbox.** If you can make a mini-app reach something it
  should not, please read [SECURITY.md](SECURITY.md) first and mail it rather
  than filing it publicly.
- **Corrections to the docs.** `docs/` tries to distinguish what is verified
  from what is assumed. Where it gets that wrong, I want to know.

## Likely to be declined

Not to waste your time:

- **A backend.** Any change that requires an aiity server, account, or
  sign-up. "There is no aiity server" is the product, not an implementation
  detail I have not gotten round to.
- **Analytics or telemetry**, in any form, however anonymous.
- **Impersonating a vendor's own CLI** to get subscription credentials working
  as an API. It technically works and it is against those vendors' terms; API
  keys are the supported path here and the app says so plainly.
- **Large refactors with no behaviour change**, unless we have talked about it
  first in an issue.

## Licensing

By contributing you agree your work is under the [MIT licence](LICENSE), same as
the rest. There is no CLA to sign.
