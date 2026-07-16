#!/usr/bin/env python3
"""OpenAI-compatible stub for hermetic end-to-end tests of AI App.

Implements:
  POST /v1/chat/completions  (stream=true SSE) — scripted agent behavior:
      1st call of a fresh chat  -> emits a web_search tool call
      call containing a tool result -> streams text + a mini-app ```html fence
      chat whose system prompt marks an editing session -> streams the
      updated mini-app (blue background) directly
  GET  /search?q=...&format=json — SearXNG-shaped results, so the app's
      web_search tool can run hermetically against this server too.

Run: python3 tools/stub_llm_server.py [port]   (default 8555)
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8555

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


def sse_chunk(delta):
    payload = {"choices": [{"index": 0, "delta": delta}]}
    return f"data: {json.dumps(payload)}\n\n".encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[stub] " + fmt % args + "\n")

    def _send_sse_headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/search"):
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

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) or b"{}"

        if self.path.endswith("/images/generations"):
            body = json.dumps({"data": [{"b64_json": self.TINY_PNG_B64}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if not self.path.endswith("/chat/completions"):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        request = json.loads(raw)
        messages = request.get("messages", [])
        system = next((m.get("content", "") for m in messages if m.get("role") == "system"), "")
        tool_texts = [m.get("content", "") for m in messages if m.get("role") == "tool"]
        last_user = next((m.get("content", "") for m in reversed(messages) if m.get("role") == "user"), "")
        editing = "editing the existing mini-app" in (system or "")
        wants_image = "bild" in last_user.lower()
        image_done = any("Bild erstellt" in (t or "") for t in tool_texts)

        self._send_sse_headers()
        if image_done:
            self.wfile.write(sse_chunk({"content": "Hier ist dein Bild."}))
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
