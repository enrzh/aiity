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
| **Translated: interpolated strings** | Yes — via the format-specifier keys Xcode extracts. See below. |

## Interpolated strings, and why the keys are not the literals

Swift rewrites `Text("Mode: \(name)")` into the catalog key `Mode: %@`. The
literal is **not** the key, and a hand-written guess at the key fails silently —
no warning, the string just falls back to German.

So the keys are not guessed. `SWIFT_EMIT_LOC_STRINGS` is on at project level,
which makes every build emit `.stringsdata` files listing exactly what Swift
looks up:

```bash
find ~/Library/Developer/Xcode/DerivedData/AIApp-*/Build/Intermediates.noindex/AIApp.build \
  -name '*.stringsdata' | xargs -I{} python3 -c "
import json,sys; d=json.load(open('{}'))
[print(e['key']) for t in d.get('tables',{}).values() for e in t if 'key' in e]"
```

That list is the ground truth. Anything in it that is missing from the catalog
falls back to German; anything in the catalog that is not in it is dead.

**A mismatched specifier is worse than a missing translation.** Swift fills
`%@` and `%lld` positionally: swap them and a number lands where a name should,
drop one and it can crash. Every translation is checked for identical specifier
counts before it is merged. If a language genuinely needs a different word
order, use positional forms — `%1$@ %2$@` — never a silent reorder.

## Strings outside SwiftUI need wrapping

`Text("…")` takes a `LocalizedStringKey` and localizes on its own. A plain
assignment does not:

```swift
errorMessage = "Kein Modell gewählt"                    // never localized
errorMessage = String(localized: "Kein Modell gewählt") // localized
```

This bit once: 116 catalog entries existed for strings that were never looked
up, so the catalog looked complete while the app was ~60% translated. If you add
user-facing text outside a SwiftUI view, wrap it.

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
