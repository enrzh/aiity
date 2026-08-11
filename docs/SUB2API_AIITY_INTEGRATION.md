# Sub2API integration contract

Aiity remains compatible with any ordinary OpenAI-compatible Sub2API server.
The endpoints below are optional enhancements for zero-touch setup.

## Capability manifest

`GET /.well-known/aiity` may return:

```json
{
  "apiVersion": 1,
  "serverVersion": "2.4.0",
  "openAIBaseURL": "/v1",
  "features": ["chat", "tools", "images"],
  "models": {
    "chat": "claude-sonnet",
    "image": "gpt-image-1"
  }
}
```

The endpoint may accept the same bearer token as `/v1`. Aiity treats a missing
or invalid manifest as a normal OpenAI-compatible server and continues with
`GET /v1/models` plus a short non-streaming chat probe.

## Device enrollment

The Sub2API administration UI creates a single-use, short-lived enrollment
token and renders this QR value:

```text
aiity://sub2api/enroll?gateway=https%3A%2F%2Fgateway.example&token=ONE_TIME_TOKEN&name=Enricos-iPhone
```

Aiity sends it once:

```http
POST /api/aiity/enroll
Content-Type: application/json

{"token":"ONE_TIME_TOKEN","deviceName":"Enricos-iPhone"}
```

Successful response:

```json
{"apiKey":"sk-device-specific","label":"Enricos iPhone"}
```

The returned key should be independently revocable and may be restricted by
models, capabilities, rate, and expiry. Never put an administrator key in the
QR payload. Aiity explicitly rejects common administrator-key fields.

## Security requirements

- Consume enrollment tokens atomically and allow each token exactly once.
- Expire unused tokens quickly.
- Store only a hash of enrollment tokens server-side.
- Issue a new device key; never return an existing administrator credential.
- Redact authorization headers and enrollment tokens from logs.
- Prefer HTTPS or Tailscale Serve. Plain HTTP is appropriate only on a trusted
  private network.
- Return `401` for an invalid device key and `403` for a capability restriction.

## Diagnostics

Aiity persists only timestamp, success, server version, latency, model count,
and failed stage. Keys, tokens, URLs, model responses, and raw server error
bodies are not written to the health record or diagnostics breadcrumb.
