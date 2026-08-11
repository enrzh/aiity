# Aiity Build 17 Product Completion Design

## Goal

Complete the four highest-value product gaps for Aiity 1.0.0 (17), verify the release, and upload it to TestFlight without assigning internal or external testers and without attaching it to a public beta group.

## Constraints

- Reuse existing SwiftUI views, provider models, `ConnectionProbe`, `MediaStore`, mini-app capability/consent types, CSP generation, and WebKit isolation.
- Add no third-party dependencies and no new root tabs.
- Keep all persisted `Codable` additions backward-compatible with explicit decoding defaults.
- Keep German as the localization source language and localize every new visible string.
- Preserve mini-app denial-by-default networking and validate every allowed destination.
- Use only `gpt-5.6-luna` subagents.
- Prefer the smallest complete implementation; omit speculative extension points.

## Slice 1: Chat Workflow

Render assistant text with native SwiftUI Markdown support while keeping selectable text and existing message actions. Stabilize streaming updates through the existing `StreamingTextBuffer` and avoid forced scrolling when the user has moved away from the latest message. Show compact, non-interactive status rows for active and completed tool calls.

Add photo/file attachment selection to the existing composer using native PhotosUI and file importer APIs. Copy selected files into app-managed storage, represent attachments in the user turn, send provider-supported images through the existing media request path, and expose generated or attached media in a tap-to-preview gallery. Unsupported files remain visible and produce an explicit, localized provider-capability error rather than disappearing.

## Slice 2: Provider Onboarding

Add one guided connection sheet launched from the current Connections overview and first-run empty state. The flow asks for provider/preset, API key when required, base URL when editable, and model. It uses the existing provider catalog, per-provider settings memory, keychain, model catalog, and `ConnectionProbe`.

For custom OpenAI-compatible endpoints, normalize a pasted URL with existing settings rules, probe the model endpoint, populate returned models, and fall back to a manual model field when discovery is unavailable. Saving is allowed only after local validation; a failed network probe remains retryable and never destroys previously working settings.

## Slice 3: Mini-App Usability

Add a native icon picker for saved mini-apps. Store a short icon value with a backward-compatible default and use it consistently in library tiles and app detail surfaces. Do not add binary icon asset management.

Expose the already-modeled network capability through a per-app permission control. The first network request still requires explicit consent. Granted hosts are persisted per mini-app, passed into CSP `connect-src`, and checked by `NetworkTargetValidator` for initial requests and redirects. Revoking permission removes the grant and schedules existing WebKit store cleanup. ZIP import keeps its existing safety model while accepting nested relative asset paths already supported by the bundle validator; no general-purpose code editor is added.

## Slice 4: Release Readiness

Run focused unit/UI tests for each slice, regenerate the Xcode project if source membership changes, run the full unit suite, update the graph, and archive 1.0.0 (17) from clean committed source. Verify app and extension versions, privacy manifest presence, release-hook absence, signing, and archive integrity.

Upload build 17 to App Store Connect/TestFlight. Stop after App Store Connect accepts the package for processing. Do not assign testers, groups, external beta metadata, or public beta access. Personal/legal App Store declarations remain untouched.

## Error Handling

User-correctable failures stay in their current sheet or composer with localized recovery actions. File-copy failure never creates a dangling attachment. Provider setup writes keys/settings only after validation succeeds. Mini-app network access remains denied on malformed, private, or ungranted targets. Release commands stop on any test, signing, archive, validation, or upload failure.

## Testing

- Markdown, streaming scroll policy, tool-state rendering, attachment persistence, unsupported attachment behavior, and media preview routing.
- Provider URL normalization, preset requirements, discovered/manual model paths, failed probe preservation, and key persistence boundaries.
- Icon decoding defaults, network consent/grant/revocation, CSP host output, redirect validation, and nested ZIP path safety.
- Existing full unit suite plus release archive checks and App Store Connect upload result.

## Out of Scope

- StoreKit, subscriptions, analytics expansion, a full mini-app source editor, arbitrary binary icon uploads, new search backends, public beta enrollment, tester assignment, App Store submission, or legal/account declarations.
