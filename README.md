# Vitals

A Claude Code skill that takes a read-only health snapshot of the dev machine and its git repos in one command. When tests fail with odd file-read errors, the machine drags, or git hangs, the cause is usually the machine and not the code: a full disk, swap pressure, iCloud-evicted files, a stale `index.lock`, a pile of worktrees, or branches that exist only on this disk. One script checks all of it, tags each line `[OK]`, `[WARN]`, `[RED]`, or `[n/a]` with the threshold behind the tag, and ends with a `VERDICT: GREEN|AMBER|RED` line.

Use it when tests fail with odd file-read errors, the machine is sluggish, git hangs, before a long build or review round, at session start, when you ask about memory, disk, storage, or usage, or when you invoke `/vitals`.

The script never deletes, kills, or modifies anything. Cleanup is handed to you as What / Where / How steps.

## Install

**As a plugin:**

```
/plugin marketplace add zayvillion-dot/vitals
/plugin install vitals@vitals
```

**Manual:**

Copy `skills/vitals/` into `~/.claude/skills/`.

## Usage

```
bash ~/.claude/skills/vitals/scripts/vitals.sh [--repo <path>]... [--worktrees <dir>]... [--bundles <dir>] [--json] [--quick]
```

| Flag | Effect |
|---|---|
| `--repo <path>` | Repo to check; repeatable. Default: the git toplevel of the current directory |
| `--worktrees <dir>` | Worktrees directory; repeatable. Default: any `*-worktrees` directory beside the repo, plus `git worktree list` |
| `--bundles <dir>` | Git bundle directory. Default: `~/nle-bundles` if it exists |
| `--json` | Emit JSON (no `jq` needed) |
| `--quick` | Skip du, iCloud/dataless probes, and worktree scans; about one second |

Environment: `VITALS_REPOS`, `VITALS_WORKTREES`, `VITALS_BUNDLES` (colon-separated) apply when the flag is absent. `VITALS_GIT_TIMEOUT` (default 5 seconds) bounds `git status` and the dataless counts.

A full run finishes in roughly 10 seconds or less; every blocking probe has a timeout or is stat-only. An optional `SessionStart` hook is in `skills/vitals/references/hook-snippet.md`.

## Sample output

```
== Disk ==
[OK] /System/Volumes/Data: 44.0 GB free, 80% used  (WARN <30 GB or >85% used; RED <15 GB or >92%)
== Memory ==
[RED] swap 4.0 GB of 5.0 GB used (80%)  (WARN >50% used; RED >75%)
== iCloud ==
[RED] my-repo: 45 dataless tracked files; fix: brctl download "/Users/me/Documents/my-repo"  (RED any dataless)
== Git ==
[RED] intake-form: git status hung (>5 s); likely dataless/evicted files: /Users/me/wt/intake-form  (RED > 5 s)
[WARN] my-repo: branch feature/x has 2 unpushed commits  (WARN ahead > 0)
== Worktrees ==
[WARN] stale worktree old-leg: last commit 33 days ago  (WARN > 14 days)
== Bundles ==
[OK] 54 bundles, newest 0 h old; 3 unpushed commits  (WARN newest >= 24 h while anything unpushed)

VERDICT: RED — Memory: swap 4.0 GB of 5.0 GB used (80%) (12 red, 38 warn)
```

## Known gaps in 0.1.0

1. macOS first. Linux is best-effort: Mac-only probes (thermal, iCloud, `brctl`, `ls -O`) print `n/a`, and memory and load use `free` and `/proc`. It has had little Linux testing.
2. No history or trending. Each run is a single snapshot; nothing is stored.
3. Thresholds are fixed in the script. The only knob is `VITALS_GIT_TIMEOUT`.
4. `brctl status` can take minutes, so only the first 4 seconds of its output are scanned. A blocked zone further down is missed. Zones for uninstalled apps are ignored on purpose.
5. The dataless count covers tracked files and `.git/objects`, not untracked files or ignored directories such as `node_modules`.
6. Git probes time out at 5 seconds by default so the run stays near 10 seconds; a very slow but healthy repo can show `git status hung`.
7. The "no upstream" check counts commits not on any remote only for the first 40 such branches per repo.
8. The verdict names the first RED finding in report order, not necessarily the most severe.
9. No fix is applied for you. The report prints the command; a human runs it.

## License

MIT — see `LICENSE`.
