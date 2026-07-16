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

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        request = json.loads(self.rfile.read(length) or b"{}")
        messages = request.get("messages", [])
        system = next((m.get("content", "") for m in messages if m.get("role") == "system"), "")
        has_tool_result = any(m.get("role") == "tool" for m in messages)
        editing = "editing the existing mini-app" in (system or "")

        self._send_sse_headers()
        if editing:
            for part in ("Klar — ", "hier die Version mit blauem Hintergrund:\n\n",
                         "```html\n" + NOTES_APP_BLUE + "\n```"):
                self.wfile.write(sse_chunk({"content": part}))
        elif has_tool_result:
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
