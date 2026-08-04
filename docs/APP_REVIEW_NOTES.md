# App Review notes

Paste this into **App Store Connect → the version → App Review Information →
Notes** at submission time. It does not persist there before a build is
attached, which is why it lives here.

Two fields in that section still need you: the **phone number** (required, and
Apple does use it), and confirming **"Sign-in required" stays unchecked** — it
defaults to *checked*, and while it is checked the whole section silently
refuses to save because it wants demo credentials that this app has no concept
of.

---

aiity has no backend and no account. Sign-in is not required, so there is no demo account to supply.

To exercise the app you need one model provider. Either enter your own API key for a supported cloud provider (More → Providers), or download an on-device model (More → Providers → On device). The on-device path needs real hardware; it does not run in the Simulator.

Two things a reviewer will reasonably look at:

1) Mini-apps and guideline 2.5.2. When the user asks for a small tool, the model returns HTML/CSS/JS which is rendered in a WKWebView inside a sandbox: a strict Content-Security-Policy, storage isolated per mini-app, no access to conversations, keys or other mini-apps, and no network access unless the user explicitly grants it for that app. Nothing executes outside WebKit, and none of it changes the app's primary purpose.

2) NSAllowsArbitraryLoads. aiity is a bring-your-own-endpoint client: users point it at their own servers on the LAN or over Tailscale, which commonly speak plain HTTP. ATS honours no exception for raw IP literals, and Tailscale's CGNAT range is not covered by NSAllowsLocalNetworking, so arbitrary loads are needed to reach a user-configured gateway. Traffic to hosted providers stays HTTPS.

Reporting model output: long-press any assistant message and choose to report it. The user sees the exact text before it is sent, and only that one message is included — not the conversation, not any keys. Reports go to getaiityapp@gmail.com.

Full source code: github.com/enrzh/aiity

---

## What is already filled in App Store Connect

App **6797102952**, SKU `aiity-ios-1000`, bundle `com.aiity.app`.

| | |
|---|---|
| Name / subtitle (en) | aiity / Agents that build your tools |
| Name / subtitle (de) | aiity / Agenten, die Werkzeuge bauen |
| Category | Productivity, secondary Utilities |
| Description, keywords, promo text | English **and** German |
| Support / marketing URL | `aiity.de` (en), `aiity.de/de/` (de) |
| Copyright | 2026 Xianjie Zhan |
| Release | **Manual** — it does not go live by itself after approval |

## TestFlight

**Internal testing needs no Beta App Review.** Add people under *Users and
Access* first — an internal tester must be a user on the team (up to 100, and
each can run it on up to 30 devices). They then accept the invite in the
TestFlight app. That is the fast path to other people's phones.

**External testing does need Beta App Review** on the first build, plus the
text below.

### Beta app description

> aiity is a chat with AI agents that build the small tools you need, right in
> the conversation. Ask for an interval timer, a unit converter, a tracker for
> something only you care about — it appears as a small sandboxed app you can
> use immediately, and keep if it is any good.
>
> There is no aiity account and no aiity server. You bring your own access: an
> API key you already have, your own machine on the network, or a model running
> on the iPhone itself.

### What to test

> 1. Ask for a small tool in your own words. Does it appear, run, and do what
>    you asked? Keep it, then find it again under Apps.
> 2. Put two or three agents in one conversation and give them something to
>    disagree about. Does the lead actually decide at the end, or just summarise?
> 3. Set up whichever provider you have — a cloud API key, your own server, or
>    an on-device model — and check it answers. On-device needs real hardware.
> 4. Switch the app to your language. Anything still in German is a bug worth
>    reporting.
> 5. If it breaks: More → Diagnose → export, and attach that. It carries what
>    happened without any keys or conversation contents.

Feedback email: `getaiityapp@gmail.com` · Privacy policy: `https://aiity.de/privacy`

## Still open

- **Screenshots.** None uploaded. iPhone 6.5" wants 1242 × 2688 or 2688 × 1242.
  Generate with `AppStoreScreenshotTests` (see the README) — they are produced
  against a seeded container, so no real conversation can appear in one.
- **Age rating.** A declaration about content, and yours to make. The app shows
  output from third-party models that you do not filter; rate it accordingly
  rather than 4+.
- **DSA trader status.** App Store Connect blocks EU distribution until it is
  declared, and declaring *trader* publishes your name and home address on the
  listing. Free app, private individual, no revenue is the ordinary non-trader
  case — but it is a legal declaration about you.
- **App Privacy questionnaire.** The honest answers are "no data collected" and
  "no tracking", matching `PrivacyInfo.xcprivacy`.
- **A build.** Blocked on a release Xcode — see APP_STORE_READINESS.md.
