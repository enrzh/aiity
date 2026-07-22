# aiity

**aiity** — „AI it yourself" (von *do it yourself*). Native iOS-App (SwiftUI): Du chattest mit einem KI-Agenten — er beantwortet Fragen, recherchiert im Web und **baut dir auf Zuruf Mini-Apps**, die als eigene Seite in der App wohnen.

> Bundle-ID: **`com.aiity.app`**. URL-Schemes: `aiity://` (primary) and `aiapp://` (kept for OpenRouter OAuth redirect). Xcode target name remains `AIApp`.

## Architektur

- **Chat-first mit Threads:** Haupttab ist der Chat (`ChatView` + `ChatSession`-Agent-Loop); mehrere Unterhaltungen über die Thread-Liste (Toolbar links), alle persistent über App-Neustarts (`chat-threads.json`, v1-Format wird migriert). Generierte Mini-Apps erscheinen als Karte im Chat (Vorschau / Behalten); „Behalten“ legt sie in die Bibliothek (zweiter Tab, `LibraryView`, SwiftData); „Im Chat bearbeiten“ öffnet einen eigenen Editier-Thread.
- **Mini-Apps = sandboxed Web:** Eine Mini-App ist ein einzelnes selbst-enthaltenes HTML-Dokument. Der Runner (`MiniAppRunnerView`) härtet es mit strikter CSP (kein Netz, keine externen Ressourcen) und injiziert die Bridge: `miniapp.storage.get/set`, `miniapp.haptic()`, `miniapp.notify(...)`, `miniapp.health.query(...)`.
- **BYO-Modelle + Diagnose:** Provider-Katalog (Anthropic, OpenAI, OpenRouter, Gemini, Mistral, Groq, DeepSeek, xAI, Together, **Ollama / LM Studio / LocalAI**, Custom OpenAI/Anthropic, **MLX on-device**). **Verbindung testen** (`ConnectionProbe`): lädt Modelle und sendet einen kurzen Test-Chat — Fehler mit klarem Text, kein stilles Scheitern. Lokale Runtimes haben ein geführtes Host-Feld.
- **Agent-Skills als Pakete:** Settings → Agent-Skills. Built-ins plus Install von **GitHub-Style-Quellen** (`owner/repo`, `owner/repo/path@branch`, GitHub-URL) oder Markdown-URL. Format: `SKILL.md` mit optionalem YAML-Frontmatter (`name`, `summary`, `version`). Enable/Disable/Remove/Update; enabled Skills fließen in den System-Prompt.
- **Mini-App-Qualität:** Template-Katalog (todo, tracker, timer, quiz, calculator, list-form) im System-Prompt; **validate → repair**-Loop nach der Generierung (`MiniAppValidator`). Schwächere/lokale Runtimes laufen im **Template-Modus** (kein freies Pro-HTML).
- **On-Device (MLX):** kuratierter Katalog mit Download-Manager; Tool-Calls via `<tool_call>…</tool_call>`.
- **Internet-Tools:** `web_search`, `fetch_url` nativ in der App.

## Lokale Runtime (Ollama / LM Studio)

1. Einstellungen → **KI-Anbieter** → Ollama (oder LM Studio / LocalAI / Custom OpenAI).
2. **Für den Chat verwenden**.
3. Host eintragen, z. B. `http://192.168.x.x:11434` (vom iPhone aus **nicht** `localhost` des Macs — LAN-IP nutzen). Ollama: `ollama serve` auf dem Mac.
4. **Verbindung testen** — bei Erfolg erscheinen Modelle; sonst eine lesbare Fehlermeldung (HTTP/Netzwerk/JSON).
5. Modell wählen und chatten. Mini-Apps: Template-Modus empfohlen.

`NSAllowsLocalNetworking` ist gesetzt (HTTP zu Geräten im LAN).

## Skill-Pakete

```
my-skill/
  SKILL.md          # optional YAML frontmatter + markdown body
  references/       # optional (noch nicht gebündelt; Body reicht)
```

Beispiel `SKILL.md`:

```markdown
---
name: Widget Craft
summary: Builds polished widgets
version: 1.0.0
---
Always use CSS variables and 44px touch targets.
```

Install in der App:

- `owner/repo` → `raw.githubusercontent.com/…/main/SKILL.md`
- `owner/repo/skills/ui@develop` → Pfad + Branch
- volle `https://github.com/…/blob/…/SKILL.md` URL
- beliebige HTTPS-URL zu Markdown

Aktive Skills: `SkillStore.enabledInstructions()` → System-Prompt jeder neuen Unterhaltung.

## Mini-App-Pipeline

1. System-Prompt enthält **Templates** + Qualitätsregeln (+ Template-only bei lokalen/MLX-Runtimes).
2. Modell liefert ` ```html ` … ` ``` `.
3. `MiniAppDraft.extract` + `MiniAppValidator.validate` (DOCTYPE/html/head/body/viewport, keine externen URLs).
4. Bei Fehlern: **eine** automatische Repair-Runde mit Issue-Liste.
5. Draft-Karte → Behalten in der Bibliothek.

## Entwickeln

```sh
xcodegen generate
open AIApp.xcodeproj
```

CLI-Build:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation -skipMacroValidation \
  build CODE_SIGNING_ALLOWED=NO
```

Unit tests (AIAppTests):

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:AIAppTests \
  test CODE_SIGNING_ALLOWED=NO
```

## End-to-End-Test (hermetisch, ohne API-Key)

`tools/stub_llm_server.py` (Port 8555). UI-Test `AIAppUITests/FullFlowUITests`.

```sh
python3 tools/stub_llm_server.py &
# then xcodebuild test as above (full scheme)
```

`PROVIDER_SETTINGS_JSON` Env überschreibt Provider-Settings für Tests.

## Build-Hinweise

- `xcodebuild` braucht `-skipPackagePluginValidation -skipMacroValidation` (mlx-swift).
- Xcode 26/27: ggf. `xcodebuild -downloadComponent MetalToolchain`.

## Roadmap

- **v1–v4 ✅:** Chat, Mini-Apps, Provider, Skills, Threads, Bridge (Notify/Health), MLX.
- **v6 ✅ (Reliability):** Connection probe + local wizard, skill packages (GitHub), mini-app templates + validate/repair, template-mode for local models.
- **v6.1 ✅ (UX):** Stop generation, live settings in chat, active model chip, starter prompts, system-prompt budget for local/OAuth, dismissible errors.
- **v6.2 ✅ (Components + expand):** Shared modal components, onboarding, skill file/zip import, multi-file mini-apps (css/js fences), soft freemium gates, analytics façade. See `docs/IMPROVEMENT-PLAN.md`.
- **v6.3 ✅ (Models layer):** Unified catalog + probe + chat request path; auto-pick after load; capability tags; image/video tools only when supported; OpenAI API-key vs Codex OAuth UI note.
- **Later refine:** StoreKit IAP, deflate ZIP, crash reporting, multi-file library editor.
