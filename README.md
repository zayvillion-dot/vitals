# Vitals

![vitals](assets/social-preview.png)

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
| `--worktrees <dir>` | Worktrees directory; repeatable. Default: `*-worktrees` directories beside the repo. Linked worktrees from `git worktree list` are always added (not with `--quick`) |
| `--bundles <dir>` | Git bundle directory. Default: `~/nle-bundles` if it exists |
| `--json` | Emit JSON (no `jq` needed) |
| `--quick` | Skip du, `brctl status`, linked worktrees, and worktree scans. Repos still get the dataless count before `git status`, so allow up to one git timeout per repo (a second or two when healthy) |

Environment: `VITALS_REPOS`, `VITALS_WORKTREES`, `VITALS_BUNDLES` (colon-separated) apply when the flag is absent. `VITALS_GIT_TIMEOUT` (default 5 seconds) bounds every git call and every dataless count.

Every git call and every wait on a background probe is bounded by polling, so a child wedged in iCloud I/O is abandoned rather than waited on. The whole run has a 25-second budget: probes still pending after it print `[n/a] skipped: run budget exceeded` and the verdict still prints. A typical full run takes 10 to 15 seconds (the `du` probes have a 10-second cap). On iCloud paths (`~/Documents`, `~/Desktop`, `~/Library/Mobile Documents`) the script counts dataless files with stat-only `ls -lO` before any `git status` and skips `git status` unless the count is zero, so it never triggers a download. An optional `SessionStart` hook is in `skills/vitals/references/hook-snippet.md`.

## Sample output (excerpt)

```
== Disk ==
[OK] /System/Volumes/Data: 42.8 GiB free, 81% used  (WARN <30 GiB or >85% used; RED <15 GiB or >92%)
== Memory ==
[WARN] swap used 4.0 GB (50% of 8 GB RAM); allocated 5.0 GB (info)  (WARN used >25% of RAM; RED >50%)
== iCloud ==
[OK] stat-only dataless count on 2 iCloud targets: 1 clean, 1 with dataless files, 0 incomplete, 0 skipped (budget); per-target lines in Git  (git status runs only on a confirmed zero count)
== Git ==
[RED] my-repo: status skipped — 45 dataless tracked files; fix: brctl download "/Users/me/Documents/my-repo"  (RED any dataless)
[RED] intake-form: git status slow or blocked (>5 s): /Users/me/wt/intake-form  (RED > 5 s)
[WARN] my-repo: branch feature/x has 2 unpushed commits  (WARN ahead > 0)

VERDICT: RED — Git: my-repo: status skipped — 45 dataless tracked files; fix: brctl download "/Users/me/Documents/my-repo" (2 red in 1 section, 2 warn)  [12 s]
```

## Known gaps in 0.1.0

1. macOS first. Linux is untested: Mac-only probes (thermal, iCloud, `brctl`, `ls -O`) print `n/a`, and memory and load read `/proc/meminfo`, `/proc/vmstat`, and `/proc/uptime`.
2. No history or trending. Each run is a single snapshot; nothing is stored.
3. Thresholds are fixed in the script. The only knob is `VITALS_GIT_TIMEOUT`.
4. `brctl status` can take minutes, so only the first 4 seconds of its output are scanned. A blocked zone further down is missed. Zones for uninstalled apps are ignored on purpose.
5. The dataless count covers git metadata, tracked files, and the git dir's `refs` and `objects`, not untracked files or ignored directories such as `node_modules`. Resolving the repo (`git rev-parse --show-toplevel`, `git worktree list`) reads small `.git` metadata files before that count runs.
6. Branch results are repo-wide (all worktrees share one set of branches) but are printed under the name of the first target that probed them, which can be a worktree rather than the repo.
7. A worktree is called stale from the date of its HEAD commit, so a fresh worktree created on an old base commit reads as stale.
8. The "no upstream" check computes commits not on any remote only for the first 40 such branches per repo; the rest show `?`.
9. No fix is applied for you. The report prints the command; a human runs it.

## License

MIT — see `LICENSE`.
