#!/usr/bin/env python3
"""OpenAI-compatible stub for hermetic end-to-end tests of AI App.

Implements:
  POST /v1/chat/completions  (stream=true SSE) — scripted agent behavior:
      1st call of a fresh chat  -> emits a web_search tool call
      call containing a tool result -> streams text + a mini-app ```html fence
      chat whose system prompt marks an editing session -> streams the
      updated mini-app (blue background) directly
  POST /v1/chat/completions  (stream=false) — plain JSON completion ("ok"),
      the shape the in-app connection probe ("Verbindung testen") sends.
      The scripted SSE behavior above only ever sees stream=true requests.
  POST /v1/messages — Anthropic-dialect non-stream message ("ok").
  GET  /v1/models — provider model list; shape depends on STUB_MODE (below).
  GET  /api/tags — native-Ollama tag list (a real Ollama serves both this
      and the /v1 OpenAI-compat endpoints, so it is available in every mode).
  GET  /search?q=...&format=json — SearXNG-shaped results, so the app's
      web_search tool can run hermetically against this server too.
  POST /v1/images/generations — image generation. The answer shape is picked by
      STUB_IMAGE_SCENARIO or a per-request `?scenario=…` (see below); the
      default reproduces the OpenAI b64 happy path.
  GET  /generated.png — the bytes behind a `url`-shaped image answer.

Modes (env STUB_MODE, default "openai") only change the models-list dialect:
  openai     GET /v1/models -> {"data":[{"id":...}]}
  anthropic  GET /v1/models -> Anthropic-shaped {"data":[{"type":"model",...}]}
  ollama     GET /v1/models -> 404 (native Ollama has no /v1/models; the app
             must fall back to /api/tags)

Run: python3 tools/stub_llm_server.py [port]   (default 8555)
"""
import base64
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8555
MODE = os.environ.get("STUB_MODE", "openai")  # openai | anthropic | ollama

# Which answer shape the image endpoints produce. Default "b64" is the happy
# path FullFlowUITests depends on; the others reproduce the failure modes real
# providers hand back. Selectable per request (`?scenario=…`, so one server can
# serve several) or per process (STUB_IMAGE_SCENARIO).
#
#   b64          {"data":[{"b64_json": "<png>"}]}                (OpenAI gpt-image-1)
#   b64_datauri  same, but a newline-wrapped data: URI            (gateways)
#   url          {"data":[{"url": "…/generated.png"}]}            (dall-e)
#   url_expired  a url answer whose link then 403s
#   empty        {"data": []}                                     (well-formed, no image)
#   bad_request  400 + provider error envelope
#   policy       400 content-policy refusal
#   chat_only    404 on /images, image on /chat/completions       (OpenRouter)
#   chat_refusal 404 on /images, words instead of a picture
#   unauthorized 401
#   rate_limit   429
#   no_size      400 while `size` is sent, 200 once it is dropped
IMAGE_SCENARIO = os.environ.get("STUB_IMAGE_SCENARIO", "b64")
IMAGE_CHAT_SCENARIOS = {"chat_only", "chat_refusal"}

NOTES_APP = """<!doctype html>
<!-- emoji: 📝 -->
<html>
<head><title>Notizen</title><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="font-family:-apple-system;background:#fff">
<h1>Notizen</h1>
<textarea id="note" style="width:100%;height:40vh"></textarea>
<script>
(async () => {
  const el = document.getElementById('note');
  el.value = (await miniapp.storage.get('note')) || '';
  el.addEventListener('input', () => miniapp.storage.set('note', el.value));
})();
</script>
</body>
</html>"""

NOTES_APP_BLUE = NOTES_APP.replace("background:#fff", "background:#0a2a66;color:#fff")

NETWORK_APP = """<!doctype html>
<!-- emoji: 🌐 -->
<!-- capability: network -->
<html>
<head><title>Netz Demo</title><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body><h1>Netz Demo</h1><p>Diese App braucht Internet.</p></body>
</html>"""


def sse_chunk(delta):
    payload = {"choices": [{"index": 0, "delta": delta}]}
    return f"data: {json.dumps(payload)}\n\n".encode()



# --- Screenshot mode -------------------------------------------------------
# STUB_SCRIPT=screenshot serves one curated English conversation instead of the
# test fixtures. The UI in a store screenshot is the real app; only the model's
# side of the conversation is scripted, so the frames are reproducible and no
# real API credits are spent producing them.
SCREENSHOT = os.environ.get("STUB_SCRIPT") == "screenshot"

TIMER_APP = """<!doctype html>
<html><head><meta charset="utf-8"><title>Interval Timer</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
 body{margin:0;font:16px/1.5 -apple-system,sans-serif;background:#0e0d12;color:#f2f0f6;
      display:grid;place-items:center;min-height:100vh;text-align:center}
 .t{font:600 84px/1 ui-rounded,-apple-system,sans-serif;letter-spacing:-.03em;font-variant-numeric:tabular-nums}
 .p{color:#9b90ff;letter-spacing:.16em;text-transform:uppercase;font-size:13px;font-weight:700;margin-bottom:14px}
 button{margin-top:28px;padding:14px 34px;border:0;border-radius:999px;font-size:17px;font-weight:600;
        background:#6b4df2;color:#fff}
 .r{margin-top:12px;color:#8b849b;font-size:14px}
</style></head>
<body><div>
 <div class="p" id="phase">Work</div>
 <div class="t" id="clock">40</div>
 <div class="r">Round <span id="round">1</span> of 8</div>
 <button id="go">Start</button>
</div></body></html>"""

SCREENSHOT_REPLY = [
    "Here's an interval timer: 40 seconds of work, 20 of rest, eight rounds, "
    "with a tone at every switch.\n\n",
    "```html\n" + TIMER_APP + "\n```",
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[stub] " + fmt % args + "\n")

    def _send_sse_headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()

    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/v1/models") or self.path.endswith("/models"):
            if MODE == "ollama":
                # Native Ollama has no /v1/models — force the /api/tags fallback.
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
            elif MODE == "anthropic":
                self._send_json({
                    "data": [
                        {"type": "model", "id": "claude-stub-1",
                         "display_name": "Claude Stub"},
                    ],
                    "has_more": False,
                })
            else:
                self._send_json({"data": [
                    {"id": "stub-large", "object": "model"},
                    {"id": "stub-mini", "object": "model"},
                ]})
        elif self.path.startswith("/api/tags"):
            # Native-Ollama tag list (all modes — a real Ollama serves both).
            self._send_json({"models": [
                {"name": "qwen2.5:0.5b", "model": "qwen2.5:0.5b"},
            ]})
        elif self.path.startswith("/search"):
            body = json.dumps({
                "results": [
                    {"title": "Notiz-Apps im Überblick", "url": f"http://127.0.0.1:{PORT}/page",
                     "content": "Die besten minimalistischen Notiz-Apps speichern lokal."},
                ]
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/generated.png"):
            # Bytes behind a `url`-shaped image answer. The "url_expired"
            # scenario serves the HTML error page an expired link returns —
            # which must NOT end up stored as a picture.
            _, scenario = self._path_and_scenario()
            if scenario == "url_expired":
                body = b"<html><body>Link expired</body></html>"
                self.send_response(403)
                self.send_header("Content-Type", "text/html")
            else:
                body = base64.b64decode(self.TINY_PNG_B64)
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/page"):
            body = b"<html><body>Minimalistische Notiz-Apps speichern Eingaben lokal und sofort.</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    # 1x1 transparent PNG.
    TINY_PNG_B64 = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAA"
                    "C0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

    # --- image generation ---------------------------------------------------

    _last_body = ""

    def _path_and_scenario(self):
        """Splits `/v1/images/generations?scenario=policy` into both parts."""
        path, _, query = self.path.partition("?")
        scenario = IMAGE_SCENARIO
        for pair in query.split("&"):
            key, _, value = pair.partition("=")
            if key == "scenario" and value:
                scenario = value
        return path, scenario

    def _json(self, obj):
        return json.dumps(obj).encode()

    def image_generation_response(self, scenario):
        """(status, body, content-type) for POST …/images/generations."""
        png = self.TINY_PNG_B64
        if scenario == "b64_datauri":
            wrapped = "\n".join(png[i:i + 40] for i in range(0, len(png), 40))
            return 200, self._json({"data": [{"b64_json": "data:image/png;base64," + wrapped}]}), "application/json"
        if scenario in ("url", "url_expired"):
            return 200, self._json({"data": [{"url": f"http://127.0.0.1:{PORT}/generated.png?scenario={scenario}"}]}), "application/json"
        if scenario == "empty":
            return 200, self._json({"created": 1, "data": []}), "application/json"
        if scenario == "bad_request":
            return 400, self._json({"error": {
                "message": "Invalid value for 'quality'", "type": "invalid_request_error",
                "param": "quality"}}), "application/json"
        if scenario == "policy":
            return 400, self._json({"error": {
                "message": "Your request was rejected as a result of our safety system.",
                "type": "image_generation_user_error", "code": "content_policy_violation"}}), "application/json"
        if scenario in IMAGE_CHAT_SCENARIOS:
            return 404, self._json({"error": {"message": "No endpoints found for images/generations"}}), "application/json"
        if scenario == "unauthorized":
            return 401, self._json({"error": {"message": "Incorrect API key provided"}}), "application/json"
        if scenario == "rate_limit":
            return 429, self._json({"error": {"message": "Rate limit exceeded"}}), "application/json"
        if scenario == "no_size":
            length = int(self.headers.get("Content-Length", 0) or 0)
            # Body was already consumed by do_POST; it re-reads nothing, so the
            # decision is made on the recorded body instead.
            if '"size"' in (self._last_body or ""):
                return 400, self._json({"error": {
                    "message": "Unsupported parameter: 'size' is not supported with this model.",
                    "param": "size"}}), "application/json"
            del length
            return 200, self._json({"data": [{"b64_json": png}]}), "application/json"
        # default: "b64"
        return 200, self._json({"data": [{"b64_json": png, "revised_prompt": "eine rote Katze"}]}), "application/json"

    def image_chat_response(self, scenario):
        """(status, body, content-type) for the chat-completions image wire."""
        if scenario == "chat_refusal":
            return 200, self._json({"choices": [{"index": 0, "finish_reason": "stop", "message": {
                "role": "assistant", "content": "Ich kann keine Bilder erzeugen."}}]}), "application/json"
        return 200, self._json({"id": "gen-1", "choices": [{"index": 0, "finish_reason": "stop", "message": {
            "role": "assistant", "content": "Hier ist es.",
            "images": [{"type": "image_url", "image_url": {
                "url": "data:image/png;base64," + self.TINY_PNG_B64}}]}}]}), "application/json"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) or b"{}"
        # Kept so a scenario can answer differently depending on what was sent
        # (e.g. "no_size": reject while `size` is present, accept once dropped).
        self._last_body = raw.decode("utf-8", "replace")

        path, scenario = self._path_and_scenario()

        if path.endswith("/images/generations"):
            status, body, ctype = self.image_generation_response(scenario)
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # Chat-completions image wire (OpenRouter serves no /images route at
        # all). Only the image scenarios answer here; everything else falls
        # through to the scripted SSE conversation below, untouched.
        if path.endswith("/chat/completions") and scenario in IMAGE_CHAT_SCENARIOS:
            status, body, ctype = self.image_chat_response(scenario)
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.endswith("/videos"):
            body = json.dumps({
                "id": "vid_1", "status": "completed",
                "url": f"http://127.0.0.1:{PORT}/fakevideo.mp4",
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.endswith("/messages"):
            # Anthropic-dialect non-stream message — the connection probe's
            # test chat for anthropic/custom-anthropic presets.
            request = json.loads(raw)
            self._send_json({
                "id": "msg_stub", "type": "message", "role": "assistant",
                "model": request.get("model", "claude-stub-1"),
                "content": [{"type": "text", "text": "ok"}],
                "stop_reason": "end_turn",
            })
            return

        if not self.path.endswith("/chat/completions"):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        request = json.loads(raw)

        if request.get("stream") is False:
            # Non-stream completion — sent by the in-app connection probe
            # ("Verbindung testen"), never by the chat path (which always
            # streams), so the scripted SSE behavior below stays untouched.
            self._send_json({
                "id": "chatcmpl-stub", "object": "chat.completion",
                "model": request.get("model", "stub"),
                "choices": [{
                    "index": 0, "finish_reason": "stop",
                    "message": {"role": "assistant", "content": "ok"},
                }],
            })
            return

        messages = request.get("messages", [])
        system = next((m.get("content", "") for m in messages if m.get("role") == "system"), "")
        tool_texts = [m.get("content", "") for m in messages if m.get("role") == "tool"]
        last_user = next((m.get("content", "") for m in reversed(messages) if m.get("role") == "user"), "")
        editing = "You are editing" in (system or "")
        wants_image = "bild" in last_user.lower()
        # Device-data tools: lets a human drive the real confirmation sheet and
        # a real EventKit write on a simulator without an API key.
        wants_event = "termin" in last_user.lower()
        event_done = any(("eingetragen" in (t or "")) or ("abgelehnt" in (t or "")) for t in tool_texts)
        wants_network = "netz" in last_user.lower()
        image_done = any("Bild erstellt" in (t or "") for t in tool_texts)

        self._send_sse_headers()
        if SCREENSHOT:
            for part in SCREENSHOT_REPLY:
                self.wfile.write(sse_chunk({"content": part}))
            self.wfile.write(b"data: [DONE]\n\n")
            return
        if event_done:
            self.wfile.write(sse_chunk({"content": "Alles klar — siehe oben."}))
        elif wants_event and not tool_texts:
            self.wfile.write(sse_chunk({
                "tool_calls": [{
                    "index": 0, "id": "call_event_1",
                    "function": {
                        "name": "create_calendar_event",
                        "arguments": json.dumps({
                            "title": "Zahnarzt",
                            "start": "2026-09-01 09:00",
                            "end": "2026-09-01 10:00",
                            "location": "Hauptstraße 1",
                        }),
                    },
                }]
            }))
        elif image_done:
            self.wfile.write(sse_chunk({"content": "Hier ist dein Bild."}))
        elif wants_network and not tool_texts:
            for part in ("Hier ist deine Netz-App:\n\n", "```html\n" + NETWORK_APP + "\n```"):
                self.wfile.write(sse_chunk({"content": part}))
        elif wants_image and not tool_texts:
            self.wfile.write(sse_chunk({
                "tool_calls": [{
                    "index": 0, "id": "call_img_1",
                    "function": {"name": "generate_image", "arguments": json.dumps({"prompt": "eine rote Katze"})},
                }]
            }))
        elif editing:
            for part in ("Klar — ", "hier die Version mit blauem Hintergrund:\n\n",
                         "```html\n" + NOTES_APP_BLUE + "\n```"):
                self.wfile.write(sse_chunk({"content": part}))
        elif tool_texts:
            for part in ("Laut Recherche speichern gute Notiz-Apps lokal. ",
                         "Hier ist deine Mini-App:\n\n",
                         "```html\n" + NOTES_APP + "\n```"):
                self.wfile.write(sse_chunk({"content": part}))
        else:
            self.wfile.write(sse_chunk({
                "tool_calls": [{
                    "index": 0,
                    "id": "call_stub_1",
                    "function": {"name": "web_search", "arguments": json.dumps({"query": "beste Notiz-App minimalistisch"})},
                }]
            }))
        self.wfile.write(b"data: [DONE]\n\n")


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"stub listening on http://127.0.0.1:{PORT}", flush=True)
    server.serve_forever()
