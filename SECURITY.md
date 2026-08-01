# Security

aiity has no server. There is no account, no backend, no infrastructure to
attack — which removes whole categories of vulnerability and concentrates the
rest into two places: **the sandbox the mini-apps run in**, and **the handling of
your provider keys**. Those are the parts worth looking at hard.

## Reporting

Mail **<getaiityapp@gmail.com>**, or open a private report through GitHub's
*Security → Report a vulnerability*.

Please don't open a public issue for something exploitable until it is fixed.

I am one person doing this in my own time, so set your expectations
accordingly: you should hear back within a few days, not within hours. Tell me
what you found, how to reproduce it, and what an attacker gets out of it. If you
want credit in the fix commit, say so — and say how you want to be named.

There is no bug bounty. I can offer thanks and a mention, nothing else.

## Especially interesting

These are the places where a finding would actually change the product's claims:

- **Escaping the mini-app sandbox** — a generated mini-app reading your
  conversations, your keys, another mini-app's storage, or the app's own files.
  See [`Sandbox.swift`](AIApp/Support/Sandbox.swift) and
  [`MiniAppRunnerView.swift`](AIApp/Views/MiniAppRunnerView.swift).
- **Defeating the CSP** — the hardened document is generated around the model's
  markup rather than spliced into it, precisely because splicing was breakable.
  If you can get the policy dropped or weakened, that is a real finding.
- **Reaching the network without permission**, or getting past
  [`NetworkTargetValidator`](AIApp/Services/NetworkTargetValidator.swift) — in
  particular anything that lets a mini-app or a tool call reach a private
  address on the user's LAN.
- **Keys leaving the keychain** — appearing in a log, a crash report, a
  diagnostics export, a backup, or a request to anywhere other than the provider
  the user entered.
- **Anything in the diagnostics export.** It is meant to be pasteable into a
  bug report. If it can be made to contain a key or a conversation, that is a
  bug of the first order.

## Not in scope

- The model saying something wrong, offensive, or dangerous. That is the
  model's behaviour, not a vulnerability — report it as an issue if the app
  handles it badly.
- Your provider's outages, billing, or data practices. Requests go from your
  phone straight to whoever you configured; their policy applies there.
- Attacks that require an unlocked device already in the attacker's hands, or a
  jailbroken OS.
- Missing hardening that is Apple's to provide.

## What this is not

**aiity has not been security audited.** One adversarial review has been run
over the codebase — 19 confirmed findings, all fixed — and the reasoning behind
the security-relevant parts is written down rather than assumed. That is better
than nothing and it is not an audit, and I would rather say so here than let the
absence of this paragraph imply otherwise.
