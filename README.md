# aiity

**aiity** — „AI it yourself" (von *do it yourself*). Native iOS-App (SwiftUI): Du chattest mit einem KI-Agenten — er beantwortet Fragen, recherchiert im Web und **baut dir auf Zuruf Mini-Apps**, die als eigene Seite in der App wohnen.

> Interne Bezeichner (Xcode-Target `AIApp`, Bundle-ID `de.dongfang.aiapp`, URL-Scheme `aiapp://`) bleiben unverändert — nur der sichtbare Name ist „aiity".

## Architektur

- **Chat-first mit Threads:** Haupttab ist der Chat (`ChatView` + `ChatSession`-Agent-Loop); mehrere Unterhaltungen über die Thread-Liste (Toolbar links), alle persistent über App-Neustarts (`chat-threads.json`, v1-Format wird migriert). Generierte Mini-Apps erscheinen als Karte im Chat (Vorschau / Behalten); „Behalten“ legt sie in die Bibliothek (zweiter Tab, `LibraryView`, SwiftData); „Im Chat bearbeiten“ öffnet einen eigenen Editier-Thread.
- **Mini-Apps = sandboxed Web:** Eine Mini-App ist ein einzelnes selbst-enthaltenes HTML-Dokument. Der Runner (`MiniAppRunnerView`) härtet es mit strikter CSP (kein Netz, keine externen Ressourcen) und injiziert die Bridge: `miniapp.storage.get/set` (persistenter, pro App namespaced Storage), `miniapp.haptic()`, `miniapp.notify(title, body, inSeconds)` (lokale Notifications — Timer/Erinnerungen) und `miniapp.health.query(type, days)` (Apple Health read-only: steps/activeEnergy/heartRate, Tageswerte; Systemfreigabe beim ersten Zugriff). Mehr Fähigkeiten = bewusste Bridge-Erweiterungen, nie offenes Web.
- **BYO-Modell mit Provider-Katalog:** `ProviderPreset` kennt alle gängigen Anbieter — Anthropic, OpenAI, OpenRouter, Google Gemini, Mistral, Groq, DeepSeek, xAI, Together, Ollama, LM Studio, LocalAI — plus **„Eigener Server“** in beiden Dialekten (OpenAI-kompatibel und Anthropic Messages API) für selbst gehostete KI und **lokal auf dem Gerät via Apple MLX** (`mlx-swift-lm`, gepinnt auf 2.31.x). Zwei Wire-Dialekte decken alles ab; alle mit Token-Streaming und Tool-Calls. API-Keys liegen ausschließlich im Keychain. Kein eigenes Backend.
- **Auth:** API-Key überall; **OAuth (PKCE über `ASWebAuthenticationSession`, Callback `aiapp://oauth/…`) bei OpenRouter** — der Login holt automatisch einen Key. OpenAI/Anthropic bieten Abo-OAuth für Dritt-Apps nur partner-gated an; sobald verfügbar, ist es ein Katalog-Flag.
- **Modell-Listen live:** `ModelCatalogService` holt die Modelle des Providers (`GET /models` bzw. Anthropic `/v1/models`) — Picker statt Freitext.
- **Agent-Skills:** installierbare Anleitungs-Pakete (Settings → Agent-Skills), die in den System-Prompt einfließen. Drei integrierte (UI-Design Pro, Spiele-Entwickler, Diagramme & Charts), eigene per Markdown-URL oder Editor. Dazu eine deutlich schärfere Qualitäts-Messlatte im Basis-Prompt (Dark Mode, Safe Areas, Empty States, vollständige Funktionalität).
- **On-Device-Modelle (MLX):** kuratierter Katalog (Qwen3 4B, Llama 3.2 3B, Qwen2.5 Coder 7B — alle 4-bit) mit Download-Manager in den Einstellungen; Modelle liegen unter Application Support/LocalModels. Tool-Calls laufen über die `<tool_call>`-Konvention: das Modell emittiert `<tool_call>{"name":…,"arguments":{…}}</tool_call>`, der Stream hält diese Spans zurück und die App führt das Tool nativ aus — auch lokale Modelle können also im Web recherchieren. Läuft nur auf echten Geräten (MLX braucht Metal; im Simulator kommt eine klare Fehlermeldung). Das Increased-Memory-Entitlement ist gesetzt.
- **Internet-Skills:** Der Agent hat `web_search` (SearXNG-Endpoint konfigurierbar, sonst DuckDuckGo-HTML-Fallback) und `fetch_url` (Text-Extraktion, gekappt). Die App führt Tools nativ aus — auch schwache lokale Modelle können damit recherchieren.

## Entwickeln

Projektdatei wird aus `project.yml` generiert:

```sh
xcodegen generate          # nach Änderungen an project.yml / neuen Dateien
open AIApp.xcodeproj       # oder: Xcode → Signing-Team wählen → Run
```

CLI-Build (Xcode-beta):

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

## End-to-End-Test (hermetisch, ohne API-Key)

`tools/stub_llm_server.py` ist ein OpenAI-kompatibler Stub (Port 8555) mit geskriptetem Agent-Verhalten (Websuche-Runde → Mini-App → Editier-Version) und SearXNG-Endpoint. Der UI-Test `AIAppUITests/FullFlowUITests` fährt den kompletten Flow: Frage mit Websuche → Mini-App behalten → in der Bibliothek öffnen → per Chat iterieren → Neustart-Persistenz.

```sh
python3 tools/stub_llm_server.py &
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project AIApp.xcodeproj -scheme AIApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO
```

Die Provider-Settings lassen sich für Tests/Debugging per Env-Variable `PROVIDER_SETTINGS_JSON` überschreiben (Launch-Argumente scheitern an UserDefaults' Plist-Parsing von JSON-Braces).

## Build-Hinweise

- `xcodebuild` braucht `-skipPackagePluginValidation -skipMacroValidation` (mlx-swift bringt Build-Plugins mit; in der Xcode-GUI erscheint stattdessen einmalig ein Trust-Dialog).
- Xcode 26/27: Metal-Toolchain ist eine Download-Komponente — einmalig `xcodebuild -downloadComponent MetalToolchain`, sonst schlägt der mlx-swift-Build fehl.

## Roadmap

- **v1 ✅:** Chat + Streaming, Mini-App-Generierung, Sandbox-Runner mit Bridge, Bibliothek inkl. „Im Chat bearbeiten“, Chat-Persistenz, BYO-Key-Settings, Web-Tools, hermetischer E2E-Test.
- **v2 ✅ (lokale Modelle):** MLX-Provider mit Modell-Katalog + Download-Manager, `<tool_call>`-Konvention für Internet-Skills lokaler Modelle.
- **v3 ✅ (Provider & Skills):** Provider-Katalog (alle gängigen Anbieter + eigene Server), OpenRouter-OAuth (PKCE), automatisches Modell-Fetching, Agent-Skills, Qualitäts-Prompt.
- **v4 ✅ (Threads & Bridge):** mehrere Chat-Threads (Liste, Wechsel, Löschen, Migration), Bridge-Ausbau: lokale Notifications + HealthKit read-only (Entitlement + Usage-Strings gesetzt).
- **v5:** Apple Foundation Models für kleine Edits, Abo-OAuth sobald OpenAI/Anthropic es öffnen, Freemium via StoreKit 2 (Gate: Anzahl gespeicherter Mini-Apps), Teilen/Galerie (erst hier wird ein Server nötig).
