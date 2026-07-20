# Session Recall — parser fixtures

Golden fixtures + expected records for the Session Recall log parser. They exist
so the parsing/heuristic behavior validated by the throwaway Python prototype
(`scripts/session-recall-scan.py`) survives the rewrite into Swift (Phase 1)
**without** carrying the prototype's implementation forward. See the feature
plan at `.lavish/session-recall-plan.html`.

All content is anonymized (fictional user `alice`, repos `acme-web` / `acme-api`);
no real prompts, paths, or session data. The structure mirrors the real on-disk
shapes verified against actual `~/.claude` and `~/.codex` logs.

## Layout

```
home/                              # a fake $HOME; point the parser's roots here
  .claude/projects/<encoded-cwd>/<sessionId>.jsonl
  .codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
expected.json                      # the CORRECT parse contract (not a spike snapshot)
```

## What each fixture exercises

| Fixture | Edge case |
|---|---|
| `claude/aaaaaaa1` | Normal session, string `content`, has Claude's own `ai-title` line |
| `claude/aaaaaaa2` | First user turn is a slash-command wrapper (skip it); list `content`; no aiTitle |
| `claude/aaaaaaa3` | Malformed line (skip, don't crash) + no in-record cwd (lossy dir-decode) |
| `codex/d1` | Prompt via `event_msg/user_message` (plain string); skip developer permissions block |
| `codex/e2` | First user turn is the injected history wrapper (skip); real prompt via `response_item/message` |
| `codex/f3` | No usable human prompt -> `(no prompt found)`; timestamp recovered from filename |

## Two discoveries worth knowing

1. **Claude already writes its own title.** Sessions contain an `ai-title` line
   with an `aiTitle` field (and a `last-prompt` line). Phase 1 should prefer
   `aiTitle` when present instead of generating one — free, and matches what the
   Claude UI shows. `expected.json` records `ai_title` where present.

2. **The encoded Claude dir name is a lossy cwd source.** `/` is encoded as `-`,
   so `acme-web` and `acme/web` both encode to `...-acme-web`. cwd MUST come from
   the in-record `cwd` field (or, in-app, the Phase 2 launch ledger). Decoding
   the dir name is a last-ditch, explicitly-lossy fallback.

## How the contract was captured

The prototype was run against this tree via `HOME` override:

```sh
HOME="$PWD/Tests/Fixtures/SessionRecall/home" \
  python3 scripts/session-recall-scan.py --json
```

Fields the spike got right were snapshotted; the two rows it got **wrong** were
corrected to the intended behavior and logged under `prototype_deltas` in
`expected.json`. Those deltas are Phase 1 requirements:

- Codex parser must read `event_msg/user_message`, not only `response_item/message`.
- cwd must never be trusted from the encoded dir name.

## Using these in Phase 1 (Swift)

Point the Swift parser's Claude/Codex roots at `home/.claude/projects` and
`home/.codex/sessions`, parse, and assert each result against `expected.json`.
Assert `cwd`/`repo` only where `cwd_recovery == "in-record"`; for `ambiguous`,
assert everything except cwd/repo.
