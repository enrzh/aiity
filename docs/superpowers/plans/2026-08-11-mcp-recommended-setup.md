# MCP Recommended Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make remote MCP connections understandable and guide users to vetted provider setup pages before testing a connection.

**Architecture:** Add static recommendation metadata beside the persisted MCP profile model. Present catalog cards and Google teaching cards in `MCPServersView`; selecting one opens the existing editor with ordered setup instructions and a direct external link. The existing `MCPClient` handshake remains the only activation boundary.

**Tech Stack:** Swift 5, SwiftUI, XCTest, URL/Keychain persistence.

## Global Constraints

- Support only remote Streamable HTTP MCP servers with optional Bearer tokens.
- Do not operate an aiity backend or implement Google OAuth.
- Never ship provider endpoint or token values as ready user connections.
- Tokens stay exclusively in Keychain; profiles only retain discovered tool schemas.

---

### Task 1: Recommendation Catalog and Draft Policy

**Files:**
- Modify: `AIApp/Services/MCPService.swift`
- Modify: `AIAppTests/MCPServiceTests.swift`

**Interfaces:**
- Produces `MCPRecommendation`, `MCPRecommendation.catalog`, and `makeProfileDraft()`.
- Consumes `MCPServerProfile` without changing its persisted schema.

- [ ] Write a failing test that every catalog item has an HTTPS setup URL and produces a blank, disabled profile draft.
- [ ] Run `xcodebuild test ... -only-testing:AIAppTests/MCPServiceTests`; expect `MCPRecommendation` to be absent.
- [ ] Define `MCPRecommendation` with name, summary, system image, setup URL, and Google-service capability labels. Use direct HTTPS setup pages only; remove empty Google templates from `MCPServerProfile`.
- [ ] Re-run the focused test; expect all MCP service tests to pass.
- [ ] Commit with `feat: add MCP recommendation catalog`.

### Task 2: Guided MCP Setup UI

**Files:**
- Modify: `AIApp/Views/MCPServersView.swift`
- Modify: `AIAppTests/MCPServiceTests.swift`

**Interfaces:**
- Consumes `MCPRecommendation.catalog` and `makeProfileDraft()`.
- Produces recommendation cards, Google teaching cards, and an editor accepting `recommendation: MCPRecommendation?`.

- [ ] Write a failing source-contract test for an `Empfohlen` section, an external `Link(destination: recommendation.setupURL)`, and a secondary custom Streamable HTTP entry.
- [ ] Run the focused test; expect it to fail against the current raw Google-template buttons.
- [ ] Replace those buttons with recommendation cards. Show a compact MCP privacy explanation first. Make Google services teaching-only cards linked to a compatible recommended provider.
- [ ] Add ordered setup copy and the direct setup link to the shared editor when launched from a recommendation. Retain editable endpoint/token fields.
- [ ] Keep new profiles disabled until `MCPClient.discover` succeeds and returns one or more tools. Empty results surface an error and stay disabled.
- [ ] Re-run `MCPServiceTests` and `ChatPresentationTests`; expect zero failures.
- [ ] Commit with `feat: guide MCP provider setup`.

### Task 3: Verification and Next Build

**Files:**
- Modify: `project.yml`
- Generated: `AIApp.xcodeproj/project.pbxproj`

- [ ] Set both `CURRENT_PROJECT_VERSION` values to `20`.
- [ ] Run `xcodegen generate` and the complete `AIAppTests` target on simulator `084680DC-DFE9-47D4-9E62-FF4D597374F0`; expect zero failures.
- [ ] Run `graphify update .` and `git diff --check`; expect a refreshed graph and no whitespace errors.
- [ ] Commit with `chore: bump next TestFlight build`.
