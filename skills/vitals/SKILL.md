---
name: vitals
description: Use when tests fail with odd file-read errors, the machine feels sluggish, git hangs, before a long build or review round, at session start, when the user asks about memory, disk, storage, or usage, or invokes /vitals.
---

# Vitals

## Overview

One run of `scripts/vitals.sh` replaces a dozen ad-hoc probes. Every line carries a status tag, a metric, and the threshold that produced the tag, and the last line is a verdict. The script defines the shape of the answer: report what it prints, do not improvise a different set of checks.

## How to run

```
bash <skill-dir>/scripts/vitals.sh [flags]
```

| Flag | Effect |
|---|---|
| `--repo <path>` | Repo to check; repeatable. Default: cwd's git toplevel |
| `--worktrees <dir>` | Worktrees directory; repeatable. Default: `*-worktrees` beside the repo |
| `--bundles <dir>` | Bundle directory. Default: `~/nle-bundles` if present |
| `--quick` | Skip du, iCloud, and worktree scans (about 1 s) |
| `--json` | Machine-readable output |

Env overrides: `VITALS_REPOS`, `VITALS_WORKTREES`, `VITALS_BUNDLES` (colon-separated).

## Reading the report

Tags: `[OK]`, `[WARN]`, `[RED]`, `[n/a]`. The verdict is RED if any line is RED, AMBER if any is WARN.

- **Dataless files or `git status hung`**: evicted iCloud files. Give the human the printed `brctl download "<abs path>"` command.
- **Stale `index.lock`**: confirm no git process is running, then hand removal to the human.
- **Swap or memory RED**: name the top processes from the report; the human decides what to quit.
- **Unpushed commits or old bundles**: bundle each branch before anything else is cleaned.

Recipes, thresholds, and escalation: `references/interpretation.md`.

## Rules

- Read-only. The skill never deletes, kills, or modifies anything. Cleanup goes to the human as What / Where / How items.
- A RED verdict before a test run means do not trust a test failure until it is cleared.
- Never use `find -flags +dataless`; it is invalid on macOS. The script uses `ls -lO`.
- Quote the report's lines and verdict as printed; do not re-grade them.

## Common mistakes

| Mistake | Fix |
|---|---|
| Twelve separate probes, 60K tokens | Run the script once |
| `find -flags +dataless`, stderr hidden, empty result read as clean | Use the script's `ls -lO` count |
| Calling swap "tight rather than critical" with no number | Quote the tag and threshold |
| Skipping worktrees, bundles, unpushed branches, `brctl status` | They are in the report; read them |
| Missing stale `index.lock` or hung git | The Git section checks both |
| Deleting to fix a RED | Hand the human the fix command instead |
