# AI App

Native iOS-App (SwiftUI): Du chattest mit einem KI-Agenten — er beantwortet Fragen, recherchiert im Web und **baut dir auf Zuruf Mini-Apps**, die als eigene Seite in der App wohnen.

## Architektur

- **Chat-first:** Haupttab ist der Chat (`ChatView` + `ChatSession`-Agent-Loop). Generierte Mini-Apps erscheinen als Karte im Chat (Vorschau / Behalten); „Behalten“ legt sie in die Bibliothek (zweiter Tab, `LibraryView`, SwiftData).
- **Mini-Apps = sandboxed Web:** Eine Mini-App ist ein einzelnes selbst-enthaltenes HTML-Dokument. Der Runner (`MiniAppRunnerView`) härtet es mit strikter CSP (kein Netz, keine externen Ressourcen) und injiziert die Bridge: `miniapp.storage.get/set` (persistenter, pro App namespaced Storage) und `miniapp.haptic()`. Mehr Fähigkeiten = bewusste Bridge-Erweiterungen, nie offenes Web.
- **BYO-Modell:** `LLMProvider`-Protokoll mit zwei Adaptern — Anthropic Messages API und OpenAI-kompatibel (OpenAI, OpenRouter, **Ollama/LM Studio auf dem eigenen Rechner** via Base-URL). Beide mit SSE-Token-Streaming und Tool-Calls. API-Keys liegen ausschließlich im Keychain. Kein eigenes Backend.
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

## Roadmap

- **v1 (dieses Gerüst):** Chat + Streaming, Mini-App-Generierung, Sandbox-Runner mit Bridge, Bibliothek, BYO-Key-Settings, Web-Tools.
- **v2:** On-Device-Modelle (Apple Foundation Models für kleine Edits, MLX für echte lokale Generierung), Bridge-Ausbau (Push, HealthKit), Mini-App-Versionen/Verlauf, Chat-Historie persistieren.
- **v3:** Subscription-OAuth (Sign in with ChatGPT / Claude), Freemium via StoreKit 2 (Gate: Anzahl gespeicherter Mini-Apps), Teilen/Galerie (erst hier wird ein Server nötig).
