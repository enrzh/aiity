# Aiity Foundation Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Aiity's persistence and networking reliable, close the known correctness and security gaps, and establish a repeatable release pipeline without changing the visible product model.

**Architecture:** Introduce actor-backed repositories behind small protocols, then migrate existing observable stores without changing their public UI contracts. Route ordinary HTTP traffic through one dependency-injected client with explicit transport and security policies. Complete the work with focused correctness fixes, bounded UI-stream updates, release metadata validation, accessibility tests, and a clean integration push.

**Tech Stack:** Swift 6, SwiftUI, Swift Concurrency actors, Codable, SwiftData where already used, URLSession, WebKit, XCTest/XCUITest, XcodeGen, GitHub Actions.

## Global Constraints

- Target iOS 17 and later.
- Preserve existing conversations, agents, skills, provider profiles, mini-apps, and credentials.
- Do not weaken the existing mini-app capability sandbox or Keychain accessibility policy.
- Keep public provider traffic HTTPS-only; permit cleartext HTTP only for an explicitly confirmed private/LAN runtime.
- Do not put persistence encoding, filesystem writes, filtering, or network parsing on the main actor.
- Every storage format change must read the previous production format and have a migration test.
- Keep the current provider-facing behavior and API payload formats stable.
- Run `graphify update .` after each structural task.
- Do not mix unrelated visual redesign into this hardening pass.

---

## Intended File Structure

### Persistence

- `AIApp/Persistence/RepositoryError.swift`: shared typed persistence errors.
- `AIApp/Persistence/AtomicFileStore.swift`: atomic Codable reads/writes and timestamped corruption recovery.
- `AIApp/Persistence/ChatThreadRepository.swift`: versioned chat archive and debounced actor-backed writes.
- `AIApp/Persistence/SkillRepository.swift`: actor-backed skill storage and legacy migration.
- `AIApp/Persistence/AgentRepository.swift`: actor-backed agent storage and legacy migration.
- `AIApp/Agent/ChatCoordinator.swift`: turn orchestration extracted from `ChatSession`.
- `AIApp/Agent/ToolLoopRunner.swift`: provider/tool iteration extracted from `ChatSession`.

### Networking

- `AIApp/Networking/HTTPClient.swift`: common request execution, cancellation, status validation, and metrics.
- `AIApp/Networking/HTTPPolicy.swift`: timeout, retry, endpoint, and cleartext rules.
- `AIApp/Networking/NetworkTargetValidator.swift`: public/private address and redirect validation.
- `AIApp/Networking/SSEStreamDecoder.swift`: shared incremental server-sent-event decoding.

### Mini-App Safety

- `AIApp/Services/MiniAppStorage.swift`: bounded per-app persistence.
- `AIApp/Support/StableIdentifier.swift`: deterministic UUID generation for non-UUID app identifiers.

### Release

- `Scripts/verify-release-config.sh`: version, entitlement, privacy-manifest, and generated-project checks.
- `.github/workflows/ios.yml`: simulator build, unit tests, focused UI tests, and release validation.

---

### Task 1: Establish a Safe Integration Baseline

**Files:**
- Inspect: all files changed between `origin/main` and `main`
- Modify only if verification exposes a defect
- Verify: `AIApp.xcodeproj`, `project.yml`, `AIAppTests`, `AIAppUITests`

**Interfaces:**
- Consumes: clean local `main` at or after `bb531c2`
- Produces: a pushed, reproducible baseline on `origin/main`

- [ ] **Step 1: Confirm the worktree and ahead commits**

Run:

```bash
git status --short --branch
git log --oneline origin/main..main
git diff --check origin/main..main
```

Expected: a clean worktree, ten intentional commits, and no whitespace errors.

- [ ] **Step 2: Regenerate the Xcode project and verify no drift**

Run:

```bash
xcodegen generate
git diff --exit-code -- AIApp.xcodeproj/project.pbxproj
```

Expected: no project-file diff. If regeneration changes the project, commit `project.yml` and generated project together after reviewing the exact delta.

- [ ] **Step 3: Run the baseline build and unit suite**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'id=8B3EC27E-D74F-4FEE-A34D-AFC99BBCBA6A' \
  -skipPackagePluginValidation -skipMacroValidation \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'id=8B3EC27E-D74F-4FEE-A34D-AFC99BBCBA6A' \
  -skipPackagePluginValidation -skipMacroValidation \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  -only-testing:AIAppTests test
```

Expected: build succeeds and all 144 or more unit tests pass.

- [ ] **Step 4: Push the baseline**

Run:

```bash
git push origin main
git status --short --branch
```

Expected: `main...origin/main` with no ahead/behind marker.

---

### Task 2: Add Atomic, Versioned File Storage

**Files:**
- Create: `AIApp/Persistence/RepositoryError.swift`
- Create: `AIApp/Persistence/AtomicFileStore.swift`
- Create: `AIAppTests/AtomicFileStoreTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces:

```swift
enum RepositoryError: LocalizedError, Equatable {
    case readFailed(String)
    case decodeFailed(String)
    case writeFailed(String)
}

actor AtomicFileStore {
    func load<Value: Decodable>(
        _ type: Value.Type,
        from url: URL,
        decoder: JSONDecoder
    ) throws -> Value

    func save<Value: Encodable>(
        _ value: Value,
        to url: URL,
        encoder: JSONEncoder
    ) throws

    func quarantineCorruptFile(at url: URL, now: Date) throws -> URL
}
```

- [ ] **Step 1: Write failing tests**

Cover atomic replacement, missing-file behavior, write failure propagation, and two corrupt-file recoveries producing distinct timestamped paths.

- [ ] **Step 2: Verify the tests fail**

Run:

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'id=8B3EC27E-D74F-4FEE-A34D-AFC99BBCBA6A' \
  -only-testing:AIAppTests/AtomicFileStoreTests test
```

Expected: failure because `AtomicFileStore` does not exist.

- [ ] **Step 3: Implement atomic writes**

Encode outside the destination file, write with `.atomic`, preserve the previous file until encoding succeeds, and quarantine corrupt input under `Recovery/<filename>-<ISO8601 timestamp>`.

- [ ] **Step 4: Run focused and full tests**

Expected: the focused tests and full `AIAppTests` suite pass.

- [ ] **Step 5: Update CodeGraph and commit**

```bash
graphify update .
git add AIApp/Persistence AIAppTests/AtomicFileStoreTests.swift project.yml AIApp.xcodeproj
git commit -m "refactor: add atomic versioned persistence foundation"
```

---

### Task 3: Move Chats to an Actor-Backed Repository

**Files:**
- Create: `AIApp/Persistence/ChatThreadRepository.swift`
- Create: `AIAppTests/ChatThreadRepositoryTests.swift`
- Modify: `AIApp/Agent/AgentLoop.swift`
- Modify: `AIApp/AIAppApp.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces:

```swift
struct ChatArchiveEnvelope: Codable, Equatable {
    let schemaVersion: Int
    var threads: [ChatThread]
}

protocol ChatThreadRepositoryProtocol: Sendable {
    func load() async throws -> [ChatThread]
    func scheduleSave(_ threads: [ChatThread]) async
    func flush() async throws
}

actor ChatThreadRepository: ChatThreadRepositoryProtocol {
    init(fileURL: URL, debounce: Duration = .milliseconds(250))
}
```

- [ ] **Step 1: Add migration and debounce tests**

Test legacy raw `[ChatThread]` decoding, versioned envelope decoding, coalescing multiple saves into the newest snapshot, explicit write errors, and `flush()` on app backgrounding.

- [ ] **Step 2: Implement the repository**

Keep encoding and filesystem operations inside the repository actor. `scheduleSave` must cancel and replace its pending debounce task; `flush` must write the latest pending snapshot before returning.

- [ ] **Step 3: Inject it into `ChatSession`**

Replace direct file reads and `persist()` writes with repository calls while preserving `@Published var threads`, selected-thread behavior, and the existing UI-facing API.

- [ ] **Step 4: Flush at lifecycle boundaries**

Use `scenePhase` in `AIAppApp.swift` to call `flush()` when entering background or inactive state.

- [ ] **Step 5: Verify migration and chat behavior**

Run repository tests, `ThreadDecodingTests`, `BackupRoundTripTests`, all unit tests, and the app build.

- [ ] **Step 6: Update CodeGraph and commit**

```bash
graphify update .
git commit -am "refactor: persist chat history through an actor repository"
```

Stage newly created files explicitly before committing.

---

### Task 4: Move Skills and Agents Behind Repositories

**Files:**
- Create: `AIApp/Persistence/SkillRepository.swift`
- Create: `AIApp/Persistence/AgentRepository.swift`
- Create: `AIAppTests/SkillRepositoryTests.swift`
- Create: `AIAppTests/AgentRepositoryTests.swift`
- Modify: `AIApp/Models/SkillStore.swift`
- Modify: `AIApp/Models/AgentStore.swift`
- Modify: `AIApp/AIAppApp.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces:

```swift
protocol SkillRepositoryProtocol: Sendable {
    func load() async throws -> [AgentSkill]
    func save(_ skills: [AgentSkill]) async throws
}

protocol AgentRepositoryProtocol: Sendable {
    func load() async throws -> [AgentDefinition]
    func save(_ agents: [AgentDefinition]) async throws
}
```

- [ ] **Step 1: Test legacy migration and failed writes**

Verify existing skill and agent JSON files load unchanged and that failed writes become observable store errors instead of disappearing behind `try?`.

- [ ] **Step 2: Implement repositories using `AtomicFileStore`**

Keep the first version deliberately simple: actor isolation and atomic full-snapshot writes are sufficient because these collections are small.

- [ ] **Step 3: Preserve the observable store contracts**

Keep `SkillStore` and `AgentStore` as main-actor view models, but make them delegate persistence and expose a compact `lastPersistenceError: String?`.

- [ ] **Step 4: Replace static disk reads used during prompt assembly**

Inject immutable skill snapshots into prompt construction instead of re-reading the file synchronously from static helpers.

- [ ] **Step 5: Run all storage, skill, agent, backup, and unit tests**

- [ ] **Step 6: Update CodeGraph and commit**

```bash
graphify update .
git commit -m "refactor: isolate skill and agent persistence"
```

---

### Task 5: Introduce the Shared Hardened HTTP Client

**Files:**
- Create: `AIApp/Networking/HTTPPolicy.swift`
- Create: `AIApp/Networking/NetworkTargetValidator.swift`
- Create: `AIApp/Networking/HTTPClient.swift`
- Create: `AIAppTests/HTTPClientTests.swift`
- Create: `AIAppTests/NetworkTargetValidatorTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces:

```swift
struct HTTPPolicy: Sendable, Equatable {
    var requestTimeout: Duration
    var resourceTimeout: Duration
    var maximumRetries: Int
    var allowsPrivateCleartextHosts: Bool
}

protocol HTTPClientProtocol: Sendable {
    func data(for request: URLRequest, policy: HTTPPolicy) async throws -> (Data, HTTPURLResponse)
    func bytes(for request: URLRequest, policy: HTTPPolicy) async throws -> (URLSession.AsyncBytes, HTTPURLResponse)
}

actor HTTPClient: HTTPClientProtocol {
    init(session: URLSession, validator: NetworkTargetValidator)
}
```

- [ ] **Step 1: Write transport-policy tests**

Cover non-2xx errors, cancellation, GET retry on `429/502/503/504`, no retry for POST by default, `Retry-After`, redirect validation, public HTTP rejection, and explicitly allowed private/LAN HTTP.

- [ ] **Step 2: Implement endpoint validation**

Resolve numeric IPv4/IPv6 literals and DNS answers; reject loopback, link-local, multicast, carrier-grade NAT, private ranges, and metadata endpoints unless the caller explicitly requests private-runtime access.

- [ ] **Step 3: Implement request execution**

Use one ephemeral `URLSessionConfiguration`, deterministic timeout policy, sanitized request IDs through `Logger`, and response-size limits where callers supply one.

- [ ] **Step 4: Run focused tests**

- [ ] **Step 5: Update CodeGraph and commit**

```bash
graphify update .
git commit -m "feat: add a shared hardened HTTP transport"
```

---

### Task 6: Migrate Provider and OAuth Networking

**Files:**
- Create: `AIApp/Networking/SSEStreamDecoder.swift`
- Create: `AIAppTests/SSEStreamDecoderTests.swift`
- Modify: `AIApp/Providers/ProviderHTTP.swift`
- Modify: `AIApp/Providers/OpenAICompatibleProvider.swift`
- Modify: `AIApp/Providers/AnthropicProvider.swift`
- Modify: `AIApp/Services/ConnectionProbe.swift`
- Modify: `AIApp/Services/ModelCatalogService.swift`
- Modify: `AIApp/Services/OAuthService.swift`
- Modify: `AIApp/ViewModels/ProviderConnectionModel.swift`

**Interfaces:**
- Consumes: `HTTPClientProtocol`
- Produces:

```swift
struct SSEStreamDecoder: Sendable {
    mutating func append(_ bytes: some Sequence<UInt8>) -> [String]
    mutating func finish() -> [String]
}
```

- [ ] **Step 1: Test fragmented SSE events**

Cover CRLF/LF separators, UTF-8 split across chunks, multiple events per chunk, comments, blank data, and `[DONE]`.

- [ ] **Step 2: Replace duplicated streaming parsing**

Keep provider-specific event decoding in each provider, but use one shared framing decoder and HTTP transport.

- [ ] **Step 3: Inject the client into probes, model catalogs, and OAuth**

Preserve existing public function signatures with production defaults while allowing test injection.

- [ ] **Step 4: Add model-catalog single-flight**

Key requests by provider dialect, normalized base URL, account identifier, and credential fingerprint so concurrent views share one request without storing raw keys in cache keys.

- [ ] **Step 5: Verify provider compatibility**

Run `ProviderCompatTests`, `ModelCatalogTests`, `ConnectionProbeTests`, `OAuthServiceTests`, then all unit tests.

- [ ] **Step 6: Update CodeGraph and commit**

```bash
graphify update .
git commit -m "refactor: route providers through the shared transport"
```

---

### Task 7: Migrate Tools and Secure Remote Content

**Files:**
- Modify: `AIApp/Tools/FetchURLTool.swift`
- Modify: `AIApp/Tools/BrowserFetch.swift`
- Modify: `AIApp/Tools/WebSearchTool.swift`
- Modify: `AIApp/Tools/ImageGenerationTool.swift`
- Modify: `AIApp/Models/SkillStore.swift`
- Modify: `AIApp/Services/SkillPackage.swift`
- Modify: `AIAppTests/BrowserFetchTests.swift`
- Create: `AIAppTests/RemoteContentSecurityTests.swift`

**Interfaces:**
- Consumes: `HTTPClientProtocol`, `NetworkTargetValidator`
- Produces: no new product-facing API

- [ ] **Step 1: Add malicious-target tests**

Cover malformed SearXNG endpoints, redirects to localhost/private addresses, provider-returned image URLs targeting local resources, oversized images, non-HTTPS skill URLs, excessive skill package size, and incorrect MIME types.

- [ ] **Step 2: Remove remaining `URLSession.shared` usage**

Migrate web search, image generation/download, OAuth residual calls, and skill installation. Browser rendering may retain its WebKit navigation but must validate the initial URL and every redirect.

- [ ] **Step 3: Harden skill installation**

Require HTTPS/public targets, cap download size, validate status and MIME type, show source URL and content preview, and persist only after explicit confirmation.

- [ ] **Step 4: Verify browser fallback behavior**

Run `BrowserFetchTests`, the new security tests, tool parsing tests, and all unit tests.

- [ ] **Step 5: Update CodeGraph and commit**

```bash
graphify update .
git commit -m "fix: harden tool and skill network access"
```

---

### Task 8: Fix Turn, Recovery, Backup, and Mini-App Correctness

**Files:**
- Modify: `AIApp/Agent/AgentLoop.swift`
- Modify: `AIApp/Services/AgentLiveActivityController.swift`
- Modify: `AIApp/Services/BackupService.swift`
- Modify: `AIApp/Views/MiniAppRunnerView.swift`
- Create: `AIApp/Support/StableIdentifier.swift`
- Create: `AIApp/Services/MiniAppStorage.swift`
- Create: `AIAppTests/ChatTurnCorrectnessTests.swift`
- Modify: `AIAppTests/BackupRoundTripTests.swift`
- Create: `AIAppTests/MiniAppStorageTests.swift`

**Interfaces:**
- Produces:

```swift
struct TurnID: Hashable, Sendable { let rawValue: UUID }

struct MiniAppStorageQuota: Sendable, Equatable {
    let maximumKeys: Int
    let maximumKeyBytes: Int
    let maximumValueBytes: Int
    let maximumTotalBytes: Int
}
```

- [ ] **Step 1: Add failing regression tests**

Verify a failed new turn is not marked complete because an older assistant message exists; retry ignores source pins and synthetic repair prompts; backup restore preserves `updatedAt`; non-UUID app IDs receive distinct stable UUIDs; and storage rejects quota violations.

- [ ] **Step 2: Track Live Activity by current turn**

Record the assistant message index or `TurnID` at send time and evaluate only output created by that turn.

- [ ] **Step 3: Restrict retry candidates**

Select only visible, user-authored input and explicitly exclude mini-app source markers and generated repair instructions.

- [ ] **Step 4: Correct backup and recovery metadata**

Restore exported timestamps and retain timestamped corrupt-store recovery copies.

- [ ] **Step 5: Correct WebKit identity and storage**

Generate deterministic per-app UUIDs, enforce storage quotas outside `UserDefaults`, and recreate the web view when browser consent changes so the intended data store is actually applied.

- [ ] **Step 6: Run focused, full, and UI tests**

- [ ] **Step 7: Update CodeGraph and commit**

```bash
graphify update .
git commit -m "fix: close chat and mini-app correctness gaps"
```

---

### Task 9: Throttle Streaming UI and Add Performance Coverage

**Files:**
- Create: `AIApp/Agent/StreamUpdateBuffer.swift`
- Modify: `AIApp/Agent/AgentLoop.swift`
- Modify: `AIApp/Views/ChatView.swift`
- Create: `AIAppTests/StreamUpdateBufferTests.swift`
- Create: `AIAppTests/ChatPerformanceTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces:

```swift
actor StreamUpdateBuffer {
    init(interval: Duration = .milliseconds(40))
    func append(_ fragment: String)
    func stream() -> AsyncStream<String>
    func finish()
}
```

- [ ] **Step 1: Test batching and final flush**

Verify rapid fragments are coalesced, the final fragment is never lost, cancellation ends the stream, and updates remain ordered.

- [ ] **Step 2: Batch published text updates**

Keep provider streaming immediate internally while limiting main-actor publication to roughly 25 updates per second.

- [ ] **Step 3: Stabilize chat scrolling**

Track whether the user is near the bottom, stop forced scrolling when they move upward, and show a compact jump-to-latest action.

- [ ] **Step 4: Add scale tests**

Measure loading and filtering 10,000 messages and assert persistence scheduling does not block the main actor.

- [ ] **Step 5: Run tests, profile one long stream, update CodeGraph, and commit**

```bash
graphify update .
git commit -m "perf: batch chat streaming and persistence updates"
```

---

### Task 10: Complete Accessibility and Release Validation

**Files:**
- Modify: `AIApp/Info.plist`
- Modify: `AIApp/AIApp.entitlements`
- Modify: `AIAppLiveActivity/Info.plist`
- Modify: `AIApp/PrivacyInfo.xcprivacy`
- Modify: `project.yml`
- Create: `Scripts/verify-release-config.sh`
- Create: `.github/workflows/ios.yml`
- Modify: `AIAppUITests/FullFlowUITests.swift`
- Modify: `AIAppUITests/SettingsTourUITests.swift`
- Create: `AIAppUITests/AccessibilityUITests.swift`

**Interfaces:**
- Produces: reproducible CI and release validation; no runtime API

- [ ] **Step 1: Add the failing release validator**

The script must fail when the app and Live Activity versions differ, when the generated project differs from `project.yml`, when release configuration contains development push entitlement, or when required privacy declarations are absent.

- [ ] **Step 2: Fix release metadata**

Set app and extension versions from the same XcodeGen setting and make the push environment provisioning-controlled rather than hardcoded for release archives.

- [ ] **Step 3: Correct privacy descriptions**

State separately what remains local, what can sync through iCloud, and what is sent to a user-selected provider. Keep the manifest aligned with actual SDK and required-reason API usage.

- [ ] **Step 4: Add accessibility UI coverage**

Exercise Extra Extra Large Dynamic Type, VoiceOver labels/traits for icon controls, reduced motion, light/dark appearance, keyboard focus where applicable, and 44-point touch targets.

- [ ] **Step 5: Add CI**

CI must run XcodeGen drift validation, a single-architecture simulator build, all unit tests, focused UI smoke tests, the release validator, `git diff --check`, and a secret scan.

- [ ] **Step 6: Verify locally**

Run:

```bash
./Scripts/verify-release-config.sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'id=8B3EC27E-D74F-4FEE-A34D-AFC99BBCBA6A' \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'id=8B3EC27E-D74F-4FEE-A34D-AFC99BBCBA6A' \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test
```

- [ ] **Step 7: Update CodeGraph and commit**

```bash
graphify update .
git commit -m "ci: validate Aiity accessibility and release readiness"
```

---

### Task 11: Final Integration, TestFlight Smoke Test, and Push

**Files:**
- Review: all files changed by Tasks 2–10
- Update: `README.md` with storage, network, backup, and release behavior
- Update: `docs/IMPROVEMENT-PLAN.md` with completed items

**Interfaces:**
- Consumes: all prior tasks
- Produces: pushed `main`, validated archive, and documented TestFlight checklist

- [ ] **Step 1: Review the complete diff**

```bash
git diff origin/main...HEAD --stat
git diff --check origin/main...HEAD
git status --short
```

- [ ] **Step 2: Run the complete verification matrix**

Run unit tests, UI smoke tests, release validator, clean build, and `graphify update .`. Confirm no silent persistence errors and no `URLSession.shared` remains outside deliberately documented system integrations.

- [ ] **Step 3: Build a signed archive**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/Aiity.xcarchive archive
```

Expected: archive succeeds with matching app/extension versions and valid release entitlements.

- [ ] **Step 4: Perform the TestFlight smoke checklist**

Verify provider setup, OAuth return, API-key storage, model discovery, streaming cancellation, tool execution, mini-app creation, browser consent changes, backup export/import, CloudKit mini-app sync, background/foreground persistence, Live Activity completion/failure, Dynamic Type, VoiceOver, and dark/light appearance.

- [ ] **Step 5: Commit documentation and push**

```bash
git add README.md docs/IMPROVEMENT-PLAN.md
git commit -m "docs: record Aiity hardening and release workflow"
git push origin main
git status --short --branch
```

Expected: clean `main...origin/main`.

---

## Completion Criteria

- No conversation, agent, or skill write is performed synchronously on the main actor.
- Existing production JSON data migrates without loss.
- Ordinary application networking uses `HTTPClientProtocol`; explicit exceptions are documented and tested.
- Public credentials cannot be sent over cleartext HTTP.
- Remote images, skills, browser navigation, and redirects share hardened target validation.
- Current-turn completion, retries, backup timestamps, mini-app identities, and storage quotas have regression tests.
- A 10,000-message conversation remains responsive while streaming and saving.
- App and Live Activity versions match, release entitlements validate, and privacy text matches actual data flow.
- Build, unit tests, focused UI tests, release validation, archive, CodeGraph, and TestFlight smoke checks pass.
- `main` is clean and synchronized with `origin/main`.
