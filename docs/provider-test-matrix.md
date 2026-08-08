# Provider test matrix

How every provider connection ("Verbindung testen") and every local runtime is
verified, in four tiers. Tiers 1 and 3 are hermetic and run unattended; Tier 2
needs live keys; Tier 4 needs hardware or a human.

The contract all tiers test against: **a green probe is a diagnosis, not a
configuration.** The probe and "Modelle laden" only *suggest* a model (picker
highlight); `commitModel` fires solely from the explicit picker/text bindings,
and leaving an active provider without a committed model raises the
"Kein Modell gewählt" exit prompt (`provider-back`).

## Tier 1 — hermetic unit tests (per commit, no keys, no network)

Run with the normal unit gate (also enforced by `tools/release.sh` via the
executed-test count):

```sh
xcodebuild test -project AIApp.xcodeproj -scheme AIApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:AIAppTests
```

- `ProviderPresetCatalogTests` — per-preset invariants over all 16 presets:
  unique ids, models-list URL + test-chat request construction for both wire
  dialects, needsKey/editableBaseURL/oauth consistency,
  `MediaCapability.imagePresetIds` ⊆ catalog, the `.verified` evidence list.
- `ConnectionProbeTests` — parsers, plus the FULL `ConnectionProbe.test()`
  against an in-process HTTP stub (`ProbeStubServer`, ephemeral port) for all
  three wire shapes: OpenAI-compat, Anthropic (`/v1/messages`), native Ollama
  (`/api/tags` fallback after a 404 on `/v1/models`); error surfacing for
  401/404/timeout; auth-header matrix (Bearer vs `x-api-key` vs
  OAuth-marker + `anthropic-beta`).

`ProbeStubServer` mirrors the response shapes of `tools/stub_llm_server.py`
but lives inside the test process, so the unit suite needs no Python server.

## Tier 2 — key-gated live smoke (nightly / pre-release, costs money)

`ProviderLiveSmokeTests` — one test per hosted preset. Each SKIPS unless its
key is present, so the suite is green in CI by design. With a key it runs the
same probe as the in-app button: live models list + one short test chat.

| Preset      | Env var                     | Key provisioned? |
|-------------|-----------------------------|------------------|
| anthropic   | `AIITY_TEST_KEY_ANTHROPIC`  | no |
| openai      | `AIITY_TEST_KEY_OPENAI`     | no |
| openrouter  | `AIITY_TEST_KEY_OPENROUTER` | no |
| gemini      | `AIITY_TEST_KEY_GEMINI`     | no |
| mistral     | `AIITY_TEST_KEY_MISTRAL`    | no |
| groq        | `AIITY_TEST_KEY_GROQ`       | no |
| deepseek    | `AIITY_TEST_KEY_DEEPSEEK`   | no |
| xai         | `AIITY_TEST_KEY_XAI`        | no |
| together    | `AIITY_TEST_KEY_TOGETHER`   | no |

No keys are provisioned yet. Groq, Gemini, OpenRouter and Mistral have free
tiers — provision those four first, plus existing Anthropic/OpenAI keys.
**Anthropic must be a plain API key** — subscription OAuth tokens are
rate-limited outside Claude Code and would flake the smoke.

xcodebuild forwards env vars to the test runner only with the `TEST_RUNNER_`
prefix:

```sh
TEST_RUNNER_AIITY_TEST_KEY_GROQ=gsk_… \
xcodebuild test -project AIApp.xcodeproj -scheme AIApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:AIAppTests/ProviderLiveSmokeTests
```

A green run here is the evidence that flips a preset to
`ProviderMaturity.verified` (update `ProviderPreset.swift` AND
`ProviderPresetCatalogTests.testVerifiedTierMatchesTheEvidenceList` together).

## Tier 3 — hermetic UI tests (simulator + local stub)

Start the stub, then run the UI suite (same pattern as `FullFlowUITests`):

```sh
python3 tools/stub_llm_server.py 8555 &
xcodebuild test -project AIApp.xcodeproj -scheme AIApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:AIAppUITests/ConnectionTestUITests
```

`ConnectionTestUITests` navigates Mehr → KI-Anbieter → Ollama, taps
`test-connection`, asserts the green "Verbunden" row, and proves the probe
committed no model (the `provider-back` exit prompt still intercepts); the
second test proves an explicit pick commits and releases the prompt.

The stub also has models-list modes for manual experiments
(`STUB_MODE=anthropic` / `STUB_MODE=ollama`); the default OpenAI mode is what
the UI tests use.

## Tier 4 — device / manual checklist (once per release)

### MLX on-device (real iPhone; the simulator refuses MLX by design)

The in-app probe returns ok for MLX without inference — the real check is the
self-test harness:

```sh
xcrun devicectl device process launch --console \
  --environment-variables '{"AIITY_MLX_SELFTEST":"mlx-community/Llama-3.2-1B-Instruct-4bit"}' \
  com.aiity.app
# expect "AIITY-MLX OK" on the console; repeat with a mid-size (3B) model
```

- [ ] 1B model: `AIITY-MLX OK`
- [ ] 3B model: `AIITY-MLX OK`
- [ ] Group round on-device: `AIITY_GROUP_SELFTEST=<frage>` prints the
      `AIITY-GROUP` transcript (do NOT run 3 MLX agents in one round — jetsam)

### Ollama / LM Studio over LAN (real iPhone)

- [ ] Mac: `ollama serve` + `ollama pull qwen2.5:0.5b`; iPhone → Ollama →
      enter the Mac's LAN IP (`http://<mac-ip>:11434`) → "Verbindung testen"
      green with a non-empty model list → one real chat reply
- [ ] Mac: `lms server start`; iPhone → LM Studio → `http://<mac-ip>:1234` →
      probe green → one real chat reply
- Note: ATS allows arbitrary loads in this app, but the iPhone must be on the
  same Wi-Fi (or Tailscale) — `localhost` on the phone is the phone.

### sub2api over Tailscale

- [ ] Gateway reachable from the phone via HTTPS (Tailscale Serve — iOS
      blocks cleartext to the raw Tailscale IP), sk-… key added as Konto,
      "Verbindung testen" green, one real chat reply
- [ ] Image slot on sub2api: one 256px generate_image round (billable — only
      when releasing image features)

### OAuth flows (interactive by nature; unit tests cover the parsing)

- [ ] Claude subscription pasteCode login completes and a chat streams
- [ ] OpenRouter key-exchange login completes and a chat streams

### Image modality (billable, opt-in)

- [ ] One image generation on the configured image provider (openai /
      gemini / xai / openrouter) renders inline in the chat

## Release gate bookkeeping

`tools/release.sh` asserts the executed unit-test COUNT (`MIN_TESTS`) because
a test file missing from project.yml compiles nothing and still exits 0.
When you add unit tests (including skipped live-smoke tests — skips count as
executed), raise `MIN_TESTS` deliberately.
