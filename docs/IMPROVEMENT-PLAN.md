# Improvement plan

## Done
1. Stop generation, live SettingsStore, model chip, starter prompts, prompt budget, token-param compat, dismissible errors
2. Model probe + Ollama wizard, skill packages (GitHub), mini-app templates + validate/repair
3. **Component modals** (`AIApp/Components/`): ModalChrome, AppSheet, BannerView, SuggestionList, ActiveModelChip, ConfirmModal, ThreadsSheet, PasteCodeSheet, AddSkillSheet, MiniAppSheet, OnboardingModal, ImportSkillModal, UpgradeModal
4. **Onboarding** first-run wizard
5. **Skill import** from GitHub URL + local `.md` / `.zip` (SKILL.md)
6. **Multi-file mini-apps** (` ```css:path` / ` ```js:path` ) bundled for sandbox
7. **Soft freemium** gates (local limits, UpgradeModal — no StoreKit yet)
8. **Analytics** façade (DEBUG console)

## Logic simplification (2026-07-21 cont.)
9. **Chat is main tab** (not buried fullScreenCover from Apps)
10. **Per-provider settings memory** — switching OpenAI ↔ Ollama keeps each model/baseURL
11. **System prompt refreshed every send** — skills/provider changes apply immediately
12. **Freemium gates off by default** (hook remains)
13. **Shorter tool loops** (4 rounds), clearer empty library / onboarding
14. **Modality-separated providers** — Connections list is Chat / Bild / Video slots; no nested image/video model fields inside a chat provider; media tools resolve their own provider+model

## Branding
15. **Bundle ID `com.aiity.app`** (was `de.dongfang.aiapp`); Keychain migrates secrets; URL schemes `aiity` + `aiapp`
16. **Background chat + Live Activities** — agent continues with `beginBackgroundTask`, Lock Screen / Dynamic Island progress (`AIAppLiveActivity`), completion notification if backgrounded

## Later refine (priority product gaps)
- **Custom icons** — app: Asset Catalog only today; mini-apps: emoji comment only → icon picker + PNG/`data:` icon field
- **Chat UI** — bubbles/status today; need streaming polish, tool chips, markdown, media gallery, composer attachments
- **Provider onboarding** — catalog is hand-curated; need OpenAI-compat auto-detect + popular gateway presets + “paste base URL” wizard
- **Web search** — DDG Lite scrape is fragile; prefer SearXNG default, Brave/Tavily/SerpAPI keys, better snippet + fetch pipeline
- **Mini-app network / browser** — CSP blocks all net by design; optional “network” / “browser” capability tier with permission + `connect-src`
- StoreKit 2 real IAP
- Richer zip (nested folders, assets)
- Crash reporting (e.g. MetricKit only)
- Multi-file editor UI in library
- Slim ConnectionsView further (split into components)
- Drop image/video tools from system prompt when not available

