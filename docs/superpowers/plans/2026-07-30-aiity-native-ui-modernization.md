# Aiity Native UI Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish Aiity's native iOS modernization with quieter screens, less visible text, reusable SwiftUI components, focused provider configuration modules, accessible motion, and preserved behavior.

**Architecture:** Keep the current three-tab SwiftUI application and existing stores. Extract reusable presentation primitives into `AIApp/Components`, move provider-form state into a focused observable model, and split oversized views by responsibility while retaining all existing model, provider, skill, mini-app, persistence, and sandbox contracts.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftData, XCTest, XCUITest, iOS 17+, XcodeGen.

## Global Constraints

- Preserve Chat, Apps, and More as the only root tabs.
- Preserve provider support, account storage, chat persistence, skills, mini-app generation, backups, privacy behavior, and onboarding completion state.
- Use system typography, semantic colors, native navigation, native sheets, and native controls.
- Use an 8-point spacing rhythm and minimum 44-point interactive targets.
- Keep Aiity's accent gradient only for user messages and generated mini-app artwork.
- Avoid decorative gradients, nested cards, ornamental blur, and carousel-style transitions.
- Support Dynamic Type, VoiceOver, Reduce Motion, light mode, and dark mode.
- Keep the current working-tree modernization changes as the implementation baseline.
- Do not introduce third-party UI or animation dependencies.

---

### Task 1: Shared Native UI Components

**Files:**
- Create: `AIApp/Components/AppScreen.swift`
- Create: `AIApp/Components/EmptyStateView.swift`
- Create: `AIApp/Components/SettingsRow.swift`
- Modify: `AIApp/Components/ModalChrome.swift`
- Modify: `AIApp/Support/Theme.swift`
- Create: `AIAppTests/ThemeTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces: `AppScreen<Content, ToolbarContent>`, `EmptyStateView`, `SettingsRow`, `StatusBanner`, and `Theme.Motion.animation(_:reduceMotion:)`.
- Consumes: existing `Theme` semantic spacing, radii, and accent.

- [ ] **Step 1: Add failing design-token tests**

```swift
import XCTest
@testable import AIApp

final class ThemeTests: XCTestCase {
    func testSpacingScaleIsStrictlyIncreasing() {
        XCTAssertLessThan(Theme.space1, Theme.space2)
        XCTAssertLessThan(Theme.space2, Theme.space3)
        XCTAssertLessThan(Theme.space3, Theme.space4)
    }

    func testControlHeightMeetsAppleMinimum() {
        XCTAssertGreaterThanOrEqual(Theme.controlHeight, 44)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails because `Theme.controlHeight` is missing**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:AIAppTests/ThemeTests test CODE_SIGNING_ALLOWED=NO
```

Expected: `Theme` has no member `controlHeight`.

- [ ] **Step 3: Add tokens and shared native wrappers**

Add to `Theme`:

```swift
static let controlHeight: CGFloat = 44

enum MotionStyle {
    case state, content, contextual
}

static func animation(_ style: MotionStyle, reduceMotion: Bool) -> Animation {
    if reduceMotion { return .easeOut(duration: 0.16) }
    switch style {
    case .state: return .easeOut(duration: 0.2)
    case .content: return .snappy(duration: 0.22)
    case .contextual: return .smooth(duration: 0.28)
    }
}
```

Implement native wrappers that standardize margins, empty-state structure, settings-row hierarchy, status semantics, accessibility labels, and 44-point controls without replacing system components.

- [ ] **Step 4: Regenerate the Xcode project and run tests**

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:AIAppTests/ThemeTests test CODE_SIGNING_ALLOWED=NO
```

Expected: `ThemeTests` passes.

- [ ] **Step 5: Commit**

```bash
git add AIApp/Components/AppScreen.swift AIApp/Components/EmptyStateView.swift \
  AIApp/Components/SettingsRow.swift AIApp/Components/ModalChrome.swift \
  AIApp/Support/Theme.swift AIAppTests/ThemeTests.swift project.yml AIApp.xcodeproj
git commit -m "refactor: establish native Aiity component system"
```

### Task 2: Chat Surface and Composer

**Files:**
- Create: `AIApp/Components/ChatComposer.swift`
- Create: `AIApp/Components/MiniAppTile.swift`
- Modify: `AIApp/Views/ChatView.swift`
- Modify: `AIAppUITests/FullFlowUITests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `Theme`, `StatusBanner`, `EmptyStateView`, existing `ChatSession`, `MiniAppDraft`, and `ProviderSettings`.
- Produces: `ChatComposer` callbacks for send, stop, paste, and input updates; `MiniAppTile` callbacks for preview, edit, and save.

- [ ] **Step 1: Add failing UI assertions for compact chat chrome**

Add assertions that the Chat tab exposes accessibility identifiers:

```swift
XCTAssertTrue(app.buttons["chat-threads"].exists)
XCTAssertTrue(app.buttons["active-model-chip"].exists)
XCTAssertTrue(app.buttons["chat-more"].exists)
XCTAssertTrue(app.textViews["chat-composer"].exists)
```

- [ ] **Step 2: Run the UI test and confirm missing identifiers fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:AIAppUITests/FullFlowUITests test CODE_SIGNING_ALLOWED=NO
```

Expected: one or more compact-chat identifiers are missing.

- [ ] **Step 3: Extract the composer and mini-app tile**

Move prompt entry, paste, send, and stop controls into `ChatComposer`. Keep a stable bottom safe-area inset and use `Theme.controlHeight`. Move generated mini-app presentation into `MiniAppTile`; use the accent gradient only for its artwork region.

- [ ] **Step 4: Simplify Chat toolbar and message hierarchy**

Keep only thread list, active model, and overflow actions in the toolbar. Preserve retry, streaming, tool chips, generated media, draft preview, editing context, scrolling, and all current session behavior.

- [ ] **Step 5: Run UI tests and unit tests**

Use the simulator command from Step 2 for `FullFlowUITests`, then run all `AIAppTests`.

Expected: tests pass and the composer remains visible during the full flow.

- [ ] **Step 6: Commit**

```bash
git add AIApp/Components/ChatComposer.swift AIApp/Components/MiniAppTile.swift \
  AIApp/Views/ChatView.swift AIAppUITests/FullFlowUITests.swift project.yml AIApp.xcodeproj
git commit -m "refactor: simplify Aiity chat surface"
```

### Task 3: Mini-App Library and More

**Files:**
- Modify: `AIApp/Views/LibraryView.swift`
- Modify: `AIApp/Views/SettingsView.swift`
- Modify: `AIApp/Views/SkillsView.swift`
- Modify: `AIApp/AIAppApp.swift`
- Modify: `AIAppUITests/SettingsTourUITests.swift`

**Interfaces:**
- Consumes: `MiniAppTile`, `EmptyStateView`, `SettingsRow`, existing SwiftData queries, backup service, `SkillStore`, and `openChatTab`.
- Produces: adaptive library and compact More settings index.

- [ ] **Step 1: Add failing navigation assertions**

Assert the root tab bar contains exactly Chat, Apps, and More, then verify More exposes provider and skills rows:

```swift
XCTAssertEqual(app.tabBars.buttons.count, 3)
app.tabBars.buttons["Mehr"].tap()
XCTAssertTrue(app.buttons["settings-providers"].exists)
XCTAssertTrue(app.buttons["settings-skills"].exists)
```

- [ ] **Step 2: Run `SettingsTourUITests` and confirm the identifiers fail**

Use the `iPhone 17 Pro,OS=26.4` simulator destination.

- [ ] **Step 3: Replace duplicated app-card and empty-state UI**

Use `MiniAppTile` in the library, retain long-press actions, icon editing, AI editing, web-app creation, deletion confirmation, and adaptive grid behavior.

- [ ] **Step 4: Simplify More and Skills**

Use `SettingsRow` for the More index. Keep provider setup, skills, backup, preferences, and privacy as separate destinations. Reduce skill rows to name, one status indicator, short summary, and contextual actions.

- [ ] **Step 5: Run navigation and full-flow UI tests**

Expected: three tabs, working More destinations, preserved library actions, and no duplicate Skills tab.

- [ ] **Step 6: Commit**

```bash
git add AIApp/Views/LibraryView.swift AIApp/Views/SettingsView.swift \
  AIApp/Views/SkillsView.swift AIApp/AIAppApp.swift AIAppUITests/SettingsTourUITests.swift
git commit -m "refactor: unify Aiity library and settings"
```

### Task 4: Provider Connections Decomposition

**Files:**
- Create: `AIApp/Views/Connections/ConnectionsOverviewView.swift`
- Create: `AIApp/Views/Connections/ProviderConnectionView.swift`
- Create: `AIApp/Views/Connections/ProviderAccountsView.swift`
- Create: `AIApp/Views/Connections/ModelSelectionView.swift`
- Create: `AIApp/Views/Connections/ConnectionDiagnosticsView.swift`
- Create: `AIApp/Views/Connections/LocalRuntimeSetupView.swift`
- Create: `AIApp/ViewModels/ProviderConnectionModel.swift`
- Delete: `AIApp/Views/ConnectionsView.swift`
- Create: `AIAppTests/ProviderConnectionModelTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `SettingsStore`, `AccountStore`, `OAuthService`, `LocalModelStore`, `ConnectionProbe`, `ModelCatalogService`, `ProviderPreset`, and `ModelModality`.
- Produces: `ProviderConnectionModel` as the sole owner of connection-form draft state, model loading, probe state, and account actions.

- [ ] **Step 1: Add failing model-state tests**

```swift
@MainActor
final class ProviderConnectionModelTests: XCTestCase {
    func testChangingHostKeepsEnteredCredentialDraft() {
        let model = ProviderConnectionModel(presetId: "sub2api", modality: .chat)
        model.newKey = "sk-example"
        model.hostDraft = "https://gateway.example/v1"
        XCTAssertEqual(model.newKey, "sk-example")
    }

    func testProbeResultCanBeClearedWithoutResettingForm() {
        let model = ProviderConnectionModel(presetId: "ollama", modality: .chat)
        model.hostDraft = "http://192.168.1.5:11434"
        model.clearProbeResult()
        XCTAssertEqual(model.hostDraft, "http://192.168.1.5:11434")
    }
}
```

- [ ] **Step 2: Run tests and confirm `ProviderConnectionModel` is missing**

Use the unit-test simulator command from Task 1.

- [ ] **Step 3: Create the observable connection model**

Move all form-local state from `ProviderConnectionView` into `ProviderConnectionModel`. Inject existing services through initializers with production defaults. Preserve settings and keychain storage contracts.

- [ ] **Step 4: Split the 1,071-line view**

Create six focused views. Keep copy concise in overview rows; retain provider limitations, privacy consequences, and diagnostic error detail in destination screens and footers.

- [ ] **Step 5: Regenerate the Xcode project and run provider tests**

Run `ProviderConnectionModelTests`, `ConnectionProbeTests`, `ModelCatalogTests`, `OAuthServiceTests`, `ProviderCompatTests`, and `ProviderProfilesTests`.

Expected: all provider-related tests pass.

- [ ] **Step 6: Commit**

```bash
git add AIApp/Views/Connections AIApp/ViewModels/ProviderConnectionModel.swift \
  AIAppTests/ProviderConnectionModelTests.swift project.yml AIApp.xcodeproj
git rm AIApp/Views/ConnectionsView.swift
git commit -m "refactor: split provider connection experience"
```

### Task 5: Onboarding, Sheets, Accessibility, and Motion

**Files:**
- Modify: `AIApp/Components/OnboardingModal.swift`
- Modify: `AIApp/Components/ThreadsSheet.swift`
- Modify: `AIApp/Components/AddSkillSheet.swift`
- Modify: `AIApp/Components/ImportSkillModal.swift`
- Modify: `AIApp/Components/PasteCodeSheet.swift`
- Modify: `AIApp/Components/UpgradeModal.swift`
- Modify: `AIApp/Views/LibraryView.swift`
- Modify: `AIAppUITests/FullFlowUITests.swift`
- Modify: `AIAppUITests/SettingsTourUITests.swift`

**Interfaces:**
- Consumes: shared modal chrome, native controls, `Theme.animation`, current stores and callbacks.
- Produces: consistent sheet structure, concise onboarding, accessible actions, and Reduce Motion behavior.

- [ ] **Step 1: Add failing UI checks for onboarding and sheet controls**

Verify onboarding exposes a welcome step, connection options, skip action, and minimum one primary action; verify modal cancellation controls have accessibility names.

- [ ] **Step 2: Run the targeted UI tests and confirm missing identifiers fail**

Run the two UI test classes on `iPhone 17 Pro,OS=26.4`.

- [ ] **Step 3: Apply shared modal and motion patterns**

Use `ModalChrome`, `AppSheet`, `StatusBanner`, native confirmation dialogs, and `Theme.animation`. Do not animate dimensions. Add `@Environment(\.accessibilityReduceMotion)` where custom animation remains.

- [ ] **Step 4: Verify Dynamic Type and compact layouts**

Launch UI tests with:

```swift
app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"]
```

Assert primary controls remain hittable and no required labels disappear.

- [ ] **Step 5: Run UI tests**

Expected: onboarding and all sheets remain navigable at default and accessibility text sizes.

- [ ] **Step 6: Commit**

```bash
git add AIApp/Components AIApp/Views/LibraryView.swift \
  AIAppUITests/FullFlowUITests.swift AIAppUITests/SettingsTourUITests.swift
git commit -m "refactor: unify Aiity onboarding and sheets"
```

### Task 6: Cleanup, Full Verification, and Codegraph

**Files:**
- Modify: `AIApp/Support/Theme.swift`
- Modify: UI files touched by Tasks 1 through 5 only where cleanup requires it
- Modify: `README.md`
- Update locally: `graphify-out/graph.json`

**Interfaces:**
- Consumes: all earlier task outputs.
- Produces: buildable, tested, documented native modernization.

- [ ] **Step 1: Find dead UI declarations and obsolete copy**

Run:

```bash
rg -n "accentGradient|tileGradient|Theme\\.|BannerView|SuggestionList|ActiveModelChip|ModalChrome|AppSheet" AIApp
rg -n "free-drive|map-style|Apple Maps|mAiity" AIApp README.md
```

Remove only declarations with no live call sites. Preserve provider and product functionality.

- [ ] **Step 2: Run formatting and project regeneration**

```bash
xcodegen generate
git diff --check
```

Expected: no whitespace errors and generated project contains all extracted files.

- [ ] **Step 3: Run all unit tests**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:AIAppTests test CODE_SIGNING_ALLOWED=NO
```

Expected: all `AIAppTests` pass.

- [ ] **Step 4: Run all UI tests**

Run the same command without `-only-testing:AIAppTests`.

Expected: all unit and UI tests pass.

- [ ] **Step 5: Run generic build**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation -skipMacroValidation \
  build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Update and inspect the codegraph**

```bash
graphify update . --force
graphify query "Aiity UI architecture shared components provider connections"
```

Expected: extracted connection views and shared components appear as separate nodes.

- [ ] **Step 7: Commit final cleanup**

```bash
git add AIApp AIAppTests AIAppUITests README.md project.yml AIApp.xcodeproj
git commit -m "chore: finish Aiity native UI modernization"
```

