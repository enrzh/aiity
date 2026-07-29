# Codegraph — read this first

This repo has a graphify knowledge graph at `graphify-out/graph.json`. The
same instruction lives in `AGENTS.md` (cross-tool standard). Keep them in sync.

**Before using Read, Grep, or Glob to explore the codebase, run graphify first:**
- `graphify query "<question>"` — scoped subgraph for any codebase or architecture question
- `graphify path "<A>" "<B>"` — dependency path between two symbols
- `graphify explain "<concept>"` — all nodes related to a concept

This applies to you and to every subagent you spawn — include it explicitly in
any subagent prompt that involves code exploration.

Only use Read/Grep/Glob directly once graphify has already oriented you and you
need to read/modify specific lines, or if `graphify-out/graph.json` doesn't exist yet.

- Read `graphify-out/GRAPH_REPORT.md` for broad architecture review when query/path/explain don't surface enough.
- **After modifying code files, run `graphify update .`** (AST-only, free, no API cost).
- To publish the merged multi-repo graph, run `../apps_nas/scripts/publish-codegraph.sh`. Live at https://page.aiity.de/graph

`graphify-out/` is local-only (gitignored) — never commit it.
