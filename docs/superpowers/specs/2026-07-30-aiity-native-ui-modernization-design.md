# Aiity Native UI Modernization

## Objective

Modernize Aiity as a quiet, native iOS application while preserving its current product behavior. The app should use less visible text, clearer hierarchy, consistent SwiftUI components, predictable navigation, restrained motion, and accessible light and dark appearances.

Aiity remains a chat-first product for interacting with AI models and creating sandboxed mini-apps. The redesign must not change provider support, account storage, chat persistence, skills, mini-app generation, backups, privacy behavior, or onboarding completion state.

## Design Direction

Use native iOS minimalism:

- System typography and semantic colors.
- Standard SwiftUI navigation, lists, forms, menus, sheets, alerts, and controls.
- An 8-point spacing rhythm and minimum 44-point interactive targets.
- Native materials only where they clarify layering.
- Aiity's accent gradient only for user messages and generated mini-app artwork.
- No decorative gradients, nested cards, ornamental blur, or carousel-style transitions.
- Full Dynamic Type, VoiceOver, Reduce Motion, and light/dark appearance support.

## Information Architecture

The root tab structure remains:

1. Chat
2. Apps
3. More

### Chat

Chat remains the primary working surface.

The navigation bar exposes only:

- Thread list
- Active model
- Overflow actions

The message timeline distinguishes content by role without excessive containers:

- Assistant messages use the base surface.
- User messages use the Aiity accent treatment.
- Tool activity uses a compact status row.
- Errors use a shared status banner.
- Generated mini-apps use a shared mini-app tile.

The composer remains fixed above the keyboard and owns paste, stop, send, and prompt entry behavior. Secondary options move into menus or contextual sheets.

### Apps

The mini-app library uses one adaptive tile component across compact and regular width classes.

The empty state contains:

- A short title
- One sentence
- One primary action to open Chat

Editing, icon selection, AI editing, and deletion remain available through contextual menus and native sheets.

### More

More is a compact settings index rather than a long mixed configuration form.

It links to focused destination screens for:

- Providers and models
- Skills
- Backup and export
- Preferences
- Privacy

Provider setup and diagnostics stay outside the settings index.

## Shared Component System

The component system should wrap native SwiftUI patterns instead of replacing them.

### AppScreen

Provides consistent navigation title behavior, screen margins, loading state, and optional toolbar content.

### SettingsRow

Provides a title, optional subtitle, leading system icon, optional value, and disclosure behavior. Long explanations belong in destination screens or footers.

### EmptyState

Provides one symbol, title, short supporting sentence, and optional primary action.

### StatusBanner

Replaces repeated error, warning, progress, and success treatments. Supports semantic styling, dismissal, accessibility announcements, and text selection where useful.

### MiniAppTile

Provides the shared visual and interaction treatment for mini-apps in Chat and the library.

### ProviderBadge

Shows provider identity, active state, and connection state without repeating explanatory copy.

### ModelPicker

Provides searchable model selection, capability metadata, loading state, and selected state.

### Composer

Owns prompt entry, paste, stop, send, keyboard-safe layout, and accessibility labels.

### ActionSheet

Standardizes compact contextual actions and destructive confirmation flows using native menus, confirmation dialogs, and sheets.

## Connections Decomposition

`ConnectionsView.swift` is split by responsibility:

- `ConnectionsOverviewView`: active models and provider entry points.
- `ProviderConnectionView`: provider-specific connection form.
- `ProviderAccountsView`: OAuth and API-key accounts.
- `ModelSelectionView`: model loading, filtering, capabilities, and selection.
- `ConnectionDiagnosticsView`: connection test and diagnostic result.
- `LocalRuntimeSetupView`: Ollama, LM Studio, LocalAI, and custom local endpoints.

Shared state moves into focused observable models. Views render state and dispatch actions but do not own provider networking or account mutation logic.

The existing provider behavior and storage formats remain compatible.

## Content Reduction

Visible text follows these rules:

- Use symbols for familiar actions when an accessibility label and tooltip or menu label are available.
- Keep labels for ambiguous, destructive, or high-impact actions.
- Use one short subtitle at most in list rows.
- Move setup instructions into progressive disclosure.
- Replace repeated explanatory paragraphs with contextual help or section footers.
- Keep errors specific and actionable.
- Do not hide critical provider limitations or privacy consequences.

## Layout

### Compact Width

- Use native navigation stacks and bottom tab navigation.
- Present setup and editing flows as sheets or pushed destinations.
- Avoid nested vertical scrolling.
- Keep the composer and primary actions keyboard-safe.
- Use adaptive grids with a minimum usable tile width.

### Regular Width

- Allow wider message content without stretching text beyond a readable measure.
- Use multi-column navigation only where it materially improves provider or library workflows.
- Keep controls and typography at native sizes rather than scaling the phone layout.

## Motion

Motion communicates state changes:

- Button and chip state: 180 to 220 milliseconds.
- Content insertion and selection: 180 to 240 milliseconds.
- Sheet and navigation transitions: native system behavior.
- Larger contextual transitions: up to 280 milliseconds.

Use opacity and small transforms rather than animating layout dimensions. Respect Reduce Motion by replacing movement with a short crossfade or no animation.

Streaming content must remain readable and must not trigger repeated full-layout animation.

## Visual Hierarchy

- Primary actions use the app tint or native prominent button style.
- Destructive actions use system destructive styling only.
- Secondary actions use native bordered, plain, or menu presentation.
- General chrome stays neutral.
- Status colors remain semantic and are never the only state indicator.
- Cards are reserved for mini-app previews and content that needs a clear boundary.
- Lists and forms should not wrap every section in additional containers.

## Performance

- Keep provider networking and filtering outside SwiftUI body evaluation.
- Avoid repeatedly sorting or filtering model lists during rendering.
- Keep chat rows stable during streaming.
- Lazy-render long chat and model lists.
- Prevent sheets and destination views from recreating expensive stores.
- Load provider details and diagnostics on demand.
- Preserve current background handling and Live Activity behavior.

## Error Handling

- Use `StatusBanner` for recoverable inline failures.
- Use alerts or confirmation dialogs for destructive decisions.
- Preserve entered values after connection failures.
- Show retry actions only when retrying is meaningful.
- Distinguish unavailable provider, invalid credential, unreachable host, and unsupported model errors.

## Migration Strategy

1. Treat the existing uncommitted SwiftUI modernization as the baseline and review it before editing overlapping files.
2. Establish tokens and shared components.
3. Refactor Chat and its composer.
4. Refactor the mini-app library.
5. Split Connections into focused screens and state models.
6. Simplify More, Skills, onboarding, and remaining sheets.
7. Remove replaced components, dead styles, and unused localization keys.
8. Run accessibility, motion, performance, and regression verification.

Each stage must preserve behavior and remain buildable.

## Verification

Verification covers:

- Light and dark appearances.
- Compact and regular width classes.
- Dynamic Type through accessibility sizes.
- VoiceOver names and reading order.
- Reduce Motion.
- Keyboard and composer behavior.
- Tab and navigation state.
- Provider connection, account, model selection, and diagnostics.
- Chat streaming, stop, retry, and thread switching.
- Mini-app generation, preview, save, edit, and deletion.
- Skills management, backup, privacy, and onboarding.

Run unit tests, UI tests, generic simulator builds, codegraph updates, and physical-device smoke tests when a device is available.

## Non-Goals

- No provider API redesign.
- No data migration.
- No new monetization implementation.
- No change to mini-app sandbox permissions.
- No new root tabs.
- No cross-platform web redesign.
- No restoration of the discontinued maps project.
