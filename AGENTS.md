# Codegraph — read this first (any coding agent)

This repo has a graphify knowledge graph at `graphify-out/graph.json`.

**Before using Read, Grep, or Glob to explore the codebase, run graphify first:**
- `graphify query "<question>"` — scoped subgraph for any codebase or architecture question
- `graphify path "<A>" "<B>"` — dependency path between two symbols
- `graphify explain "<concept>"` — all nodes related to a concept

This applies to you and to every subagent you spawn — include it explicitly in
any subagent prompt that involves code exploration. Don't skip graphify because
files are "already known" or because you're mid-plan: the graph surfaces
cross-file dependencies and inferred edges that grep/Read miss.

Only use Read/Grep/Glob directly once graphify has already oriented you and you
need to read/modify specific lines, or if `graphify-out/graph.json` doesn't exist yet.

- If `graphify-out/wiki/index.md` exists, navigate it instead of reading raw files.
- Read `graphify-out/GRAPH_REPORT.md` for broad architecture review when query/path/explain don't surface enough.
- **After modifying code files, run `graphify update .`** (AST-only, free, no API cost) to keep the graph current — this is a standing expectation, not optional.
- To publish the merged multi-repo graph to the visual viewer, run from sibling `apps_nas`:
  `../apps_nas/scripts/publish-codegraph.sh` (merges `apps_nas`, `t212-bot`, `maps`, `ai-app`).
  Live at https://page.aiity.de/graph

`graphify-out/` is local-only (gitignored) — never commit it. Do not commit API keys, `.env`, or Xcode user state.

---

# aiity (ai-app)

Native SwiftUI iOS app. Bundle ID `com.aiity.app`. See `README.md` for product overview.
