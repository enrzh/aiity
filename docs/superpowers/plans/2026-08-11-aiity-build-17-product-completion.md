# Aiity Build 17 Product Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the missing chat, provider-onboarding, and mini-app permission behavior, then verify and upload Aiity 1.0.0 (17) without assigning testers.

**Architecture:** Extend existing persistence and policy types. Keep drafts local, validate before writes, and extend current mini-app consent with host grants.

**Tech Stack:** Swift 6, SwiftUI, PhotosUI, UniformTypeIdentifiers, SwiftData, WebKit, XCTest/XCUITest, XcodeGen.

## Global Constraints

- No new dependencies or root tabs; reuse existing services and native frameworks.
- Persisted additions decode old data with explicit defaults.
- German remains the localization source; localize new visible strings.
- Mini-app networking remains deny-by-default for initial URLs and redirects.
- Run `graphify query` before exploration and `graphify update .` after code changes.
- Every subagent uses `gpt-5.6-luna` explicitly.
- Upload build 17 only; do not assign testers/groups or alter App Store declarations.

---

### Task 1: Chat Attachments

**Files:**
- Create: `AIApp/Models/ChatAttachment.swift`
- Modify: `AIApp/Providers/LLMProvider.swift`, `AIApp/Support/MediaStore.swift`, `AIApp/Agent/AgentLoop.swift`
- Modify: `AIApp/Providers/OpenAICompatibleProvider.swift`, `AIApp/Providers/AnthropicProvider.swift`
- Modify: `AIApp/Persistence/ChatThreadRepository.swift`, `AIApp/Components/ChatComposer.swift`, `AIApp/Views/ChatView.swift`
- Test: `AIAppTests/ChatAttachmentTests.swift`
- Modify: `project.yml`

**Interfaces:** `ChatAttachment` contains stable `id`, `mediaId`, `filename`, `mimeType`, and image/file `kind`; `ChatMessage.attachments` defaults to `[]`; `ChatSession.send` accepts a default-empty attachment list.

- [ ] Add failing tests for old-message decoding, attachment round trip, safe atomic copy, copy failure, and sweep retention.
- [ ] Run the focused test target and confirm compile/test failure because attachment APIs do not exist.
- [ ] Implement the model and generic `MediaStore.save(data:filename:mimeType:)`; persist copied bytes, never source URLs.
- [ ] Add failing provider-body tests for OpenAI `image_url` data parts and Anthropic base64 image sources; unsupported files must remain visible and return a localized error.
- [ ] Implement multipart provider encoding and session retry/persistence. Include attachment IDs in archive and sweep reference collection.
- [ ] Add native `PhotosPicker` plus `.fileImporter`, removable compact items, send-with-attachment-only, and existing error presentation.
- [ ] Run `xcodegen generate`, focused tests, `graphify update .`, and `git diff --check`.
- [ ] Commit with `git commit -m "feat: add chat attachments"`.

### Task 2: Chat Presentation

**Files:**
- Modify: `AIApp/Views/ChatView.swift`
- Test: `AIAppTests/ChatPresentationTests.swift`, `AIAppUITests/ChatWorkflowUITests.swift`
- Modify: `project.yml`

**Interfaces:** Add a pure near-bottom decision, a shared generated/attached media preview route, and derived active/completed/failed tool visual state. Keep persisted tool data and `StreamingTextBuffer` unchanged.

- [ ] Add failing tests for near-bottom threshold, full Markdown parsing/fallback, and tool visual-state derivation.
- [ ] Track a bottom sentinel; gate transcript/status auto-scroll when the user is away and show one jump-to-latest control. Sending returns to bottom.
- [ ] Use full native Markdown interpretation while preserving selection, plain-text fallback, and context actions.
- [ ] Present generated images and image attachments in a tap-to-preview gallery; missing media gets a localized placeholder and video keeps its current route.
- [ ] Add focused UI regressions for attachment removal/send, scroll stability, jump-to-latest, preview/dismiss, and tool progress/completion.
- [ ] Regenerate, run focused tests, update graph, check diff, and commit `feat: complete chat presentation`.

### Task 3: Transactional Provider Onboarding

**Files:**
- Modify: `AIApp/ViewModels/ProviderConnectionModel.swift`
- Modify: `AIApp/Views/Connections/ConnectionsOverviewView.swift`, `AIApp/Views/Connections/ProviderConnectionView.swift`
- Modify: `AIApp/Components/OnboardingModal.swift`
- Test: `AIAppTests/ProviderConnectionModelTests.swift`, `AIAppUITests/ConnectionTestUITests.swift`

**Interfaces:** A pure candidate builder normalizes URL/model and returns localized validation errors. Profiles, active settings, and keychain/account state commit only after a successful probe.

- [ ] Add failing tests for required key/model, invalid/empty editable URL, normalization, and preservation of previous state after validation/probe failure.
- [ ] Implement candidate construction using `ProviderSettings.normalizeBaseURL` and existing preset requirements.
- [ ] Remove URL/model/key write-through from draft changes. Fetch/probe the candidate, then perform one successful commit; failure remains retryable without persisted mutation.
- [ ] Make an empty modality slot a localized connect action that presents the same picker/form route as first-run onboarding; do not duplicate the catalog.
- [ ] Add UI tests for empty-slot launch, failed retry preservation, normalized custom endpoint commit, manual model fallback, and deferred key persistence.
- [ ] Run focused tests, update graph, check diff, and commit `feat: guide and validate provider setup`.

### Task 4: Host-Scoped Mini-App Permission

**Files:**
- Modify: `AIApp/Models/MiniAppConsent.swift`, `AIApp/Models/MiniAppCapability.swift`
- Modify: `AIApp/Networking/NetworkTargetValidator.swift`, `AIApp/Views/MiniAppRunnerView.swift`
- Modify: `AIApp/Components/MiniAppSheet.swift`, `AIApp/Views/LibraryView.swift`
- Test: `AIAppTests/MiniAppConsentTests.swift`, `AIAppTests/BrowserRunnerPolicyTests.swift`, `AIAppTests/MiniAppBundleTests.swift`
- Modify: `project.yml`

**Interfaces:** Preserve current capability APIs for sweep callers; add normalized per-app host grants and host-aware CSP/runtime checks.

- [ ] Add failing tests for legacy capability migration, app isolation, host normalization/rejection, individual revoke, revoke-all, and private/ungranted redirects.
- [ ] Store capability plus hosts in a versioned Codable record while reading existing capability-only grants; keep `grants()` returning capability values.
- [ ] Replace broad `connect-src https:` with explicit origins and require both public-target validation and an app host grant on every hop.
- [ ] Add a compact saved-app permission surface for viewing/adding/revoking hosts; reuse existing consent revoke and WebKit cleanup.
- [ ] Add regression tests for existing `iconSymbol` defaults/persistence and nested `assets/...` paths while traversal/absolute/backslash paths remain rejected.
- [ ] Regenerate, run focused tests, update graph, check diff, and commit `feat: scope mini-app network grants`.

### Task 5: Verify and Upload Build 17

**Files:** Modify release/project files only if verification exposes a real defect.

**Interfaces:** Use `tools/release.sh --upload`; final state is App Store Connect uploaded/processing with no distribution changes.

- [ ] Verify clean intended commits and `1.0.0 (17)` for app and extension.
- [ ] Run `xcodegen generate`, `graphify update .`, and `git diff --check`.
- [ ] With release Xcode selected, run `tools/release.sh` and require the configured minimum test count, archive/export success, matching versions, privacy manifest, and no debug seams.
- [ ] Run `tools/release.sh --upload` from the same clean source and require App Store Connect upload success/processing.
- [ ] Do not modify TestFlight groups/testers/public links, external beta metadata, App Review submission, privacy questionnaire, age rating, or trader status.
