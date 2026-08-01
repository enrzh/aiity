# Localization

Ten languages: German (source), English, Spanish, French, Portuguese, Italian,
Simplified Chinese, Japanese, Russian, Arabic.

**German text is the lookup key.** `CFBundleDevelopmentRegion` is `de`, so a
SwiftUI `Text("Chats")` looks up `"Chats"` in
[`AIApp/Localizable.xcstrings`](../AIApp/Localizable.xcstrings) and needs no
code change at all. That is why most of this app localized without touching the
views.

## What is and is not translated

| | |
|---|---|
| **Translated** | Interface chrome — tabs, buttons, navigation titles, settings rows, empty states, dialogs, accessibility labels. 302 keys. |
| **Not translated: prompts** | System prompts and the agent briefs in `GroupChatRunner`. These are *instructions to a model*; changing their language changes model behaviour, and the prompts already tell the model to answer in the user's language. |
| **Not translated: internal** | Diagnostics breadcrumbs, log strings, dictionary keys. They go into a technical export, not the interface. |
| **Not yet translated: interpolated strings** | 35 strings containing `\(…)`. See below. |

## The interpolated-string gap

Swift rewrites `Text("Mode: \(name)")` into the catalog key `Mode: %@` — the
literal is *not* the key. Adding those 35 strings needs each key converted to
its format-specifier form with the right specifier per argument type (`%@`,
`%lld`, `%.1f`), which is easy to get subtly wrong and fails silently: a
mismatched key just falls back to German with no warning.

They were deliberately left out rather than guessed at. They are error and
status messages — `"Model not found: \(detail)"`, `"Round \(n) of \(total)"` —
so a non-German user sees English chrome and the occasional German status line.

To finish them: build with `SWIFT_EMIT_LOC_STRINGS = YES`, let Xcode extract the
real keys into the catalog, then translate those entries.

## Adding or changing a string

1. Write it in German in the code as usual.
2. Open `AIApp/Localizable.xcstrings` in Xcode — it has a proper editor — or
   edit the JSON.
3. A key with no translation falls back to the German source, so a missing
   entry degrades rather than crashes.

## Screenshots per language

```bash
AIITY_SHOT_LANG=fr xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -resultBundlePath /tmp/shots.xcresult \
  -only-testing:AIAppUITests/ScreenshotTests test
xcrun xcresulttool export attachments --path /tmp/shots.xcresult --output-path /tmp/shots
```

The pass forces the interface language with `-AppleLanguages`, so the frames do
not depend on the simulator's own setting.
