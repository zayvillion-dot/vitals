# Interpreting the vitals report

The script is read-only. Every fix below is a step for the human; the agent proposes it as What / Where / How and does not run it.

## Disk

- **Meaning**: free space and percent used on the data volume, plus the size of Caches, Trash, and the Claude scratchpad root.
- **Why these thresholds**: below 30 GiB free (or over 85% used) APFS purgeable space, git packs, and build output start to collide; below 15 GiB (or over 92%) writes fail in odd ways. Sizes are GiB (1024³ bytes); percent used is rounded, not truncated.
- **First safe action**: report the three size lines and name the largest. Do not delete.
- **Escalate**: any RED, or Caches/Trash/scratchpad at 10 GiB or more. The human chooses what goes (empty Trash, clear scratchpad dirs, prune old worktrees after bundling).
- `size unknown (>10 s)` means `du` (stat-only, one filesystem, 10 s cap) did not finish; the directory is large or slow. Treat it as a hint, not a number. `~/.Trash` often lands here.

## Memory and swap

- **Meaning**: percent of RAM free (macOS `memory_pressure`; Linux `/proc/meminfo` MemAvailable), swap used as a share of physical RAM, cumulative pageouts. Allocated swap is printed for information only: macOS creates swap files just ahead of use, so used/allocated always looks high and is not graded.
- **Swap and uptime**: macOS grows swap over time and rarely gives it back until reboot. A long uptime with swap WARN is usually accumulated pressure, not a one-off spike. Fix order: quit the top processes, then reboot when convenient.
- **Why these thresholds**: free under 30% or swap used over 25% of RAM means paging has started to show up in latency; free under 15% or swap over 50% of RAM and tests and builds time out.
- **First safe action**: read the top-memory lines and name the heaviest. Count of `claude`, `node`, `python`, and `Code Helper` processes (names matched case-insensitively) shows runaway sessions or watchers.
- **Escalate**: RED, or uptime over 7 days with swap WARN. The human quits apps or reboots.

## CPU, thermal, uptime

- **Meaning**: 1/5/15-minute load against core count; `CPU_Speed_Limit` below 100 means thermal throttling.
- **Why**: load above the core count means a run queue; above twice the core count the machine is saturated.
- **First safe action**: check the top-CPU lines. A daemon such as `bird` (iCloud) pinned high usually points to a sync backlog (see below).
- **Escalate**: sustained RED load, or throttling. The human closes workloads or lets the machine cool.

## iCloud and dataless files

- **Meaning**: "dataless" files are iCloud placeholders whose bytes are not on disk. Any read blocks on a download and may fail or hang. Symptoms: tests fail with odd file-read errors, `git status` hangs, builds stall.
- **Detection**: `ls -lO` shows a `dataless` flag. For every target on an iCloud path (`~/Documents`, `~/Desktop`, `~/Library/Mobile Documents`), repos and worktrees alike, the script first stats the git metadata (`.git`, `HEAD`, `index`), then counts tracked files (`git ls-files -z | xargs -0 ls -lO`) and the shared git dir (`refs`, `objects`). All of it is stat-only. `git status` runs only on a confirmed zero count, because `git status` reads the content of files whose stat changed, and reading a dataless file downloads it.
- **Report lines**: `status skipped — N dataless ...` (RED) means the count was above zero and `git status` was not run. `dataless count incomplete (>N s)` (WARN) means the count itself timed out; `git status` was skipped and the state is unknown. `find -flags +dataless` is invalid on macOS; do not use it.
- **Recovery recipe** (human runs it):
  1. WHAT: materialise evicted tracked files. WHERE: Terminal in the repo. HOW: `git ls-files -z | xargs -0 -I{} brctl download "$PWD/{}"` (absolute paths only; relative paths are ignored). Or `brctl download "<repo abs path>"` for the whole directory.
  2. Re-run `vitals.sh`; the count should fall to 0. Large trees take minutes; check again.
  3. If `brctl status` shows `blocked` or `SYNC DISABLED` for a real container, sync itself is stopped: sign in again under System Settings > Apple ID > iCloud. Zones for uninstalled apps are expected and ignored.
- **Stale `index.lock` plus hung git**: a killed git leaves `.git/index.lock`. First confirm no git process is alive (the Git section lists any older than 10 minutes). Only then does the human remove the lock file named in the report.
- **`pkill -x cat` hazard**: a process stuck reading an evicted file shows up as `cat` or `git` in uninterruptible I/O. Killing it does not clear the cause and can corrupt an in-flight write. Materialise the files first; kill only with the human's say-so.
- **Escalate**: always. Materialising is the human's call because it downloads data and can fill the disk.

## Git health

- **Meaning**: branch and dirty count per repo and worktree, stale locks, hung git processes, unpushed commits per local branch, no-upstream branches with commits on no remote, broken ref names.
- **Why**: unpushed work exists only on this disk; the 2026-09-25 loss was a branch that never left it.
- **First safe action**: bundle every unpushed branch: `git bundle create <bundles-dir>/<name>.bundle <branch>`. The human pushes.
- **Broken ref names** (for example `origin/name 2`) are Finder duplicates inside `.git/refs`. They make `rev-list --remotes` fail. Bundle first, then the human removes them.
- **`git status slow or blocked (>N s)`**: `git status` ran on a tree with a confirmed zero dataless count (or a non-iCloud path) and did not finish. The cause is not known: a huge tree, a slow disk, or a lock. Re-run; if it persists, check for a stale lock and hung git processes. It is not evidence of dataless files.
- **`git status failed (rc=N)`**: git exited with an error, for example 128 for a corrupt index. Dirty count unknown; the human inspects the repo.
- **No upstream**: a branch with no upstream is flagged only when `git rev-list --count refs/heads/<b> --not --remotes` is above zero (or could not be computed, shown as `?`). A no-upstream branch whose commits are all on some remote is fine.
- **Run budget**: the whole run stops waiting at 25 s. Anything still pending prints `[n/a] skipped: run budget exceeded`; the verdict still prints.

## Worktrees

- **Meaning**: count and age of worktrees, plus strays: loose directories, `*.bundle` files, Finder duplicates (`name 2`).
- **Why**: more than 8 worktrees multiplies iCloud sync load and unpushed risk; stale ones hold unmerged work nobody remembers.
- **Hygiene rule**: bundle every branch before deleting a worktree, confirm the bundle verifies (`git bundle verify`), then the human removes the worktree. Move bundles out of the worktrees directory so they stop reading as strays.
- **Escalate**: stale worktrees with unpushed commits. The human decides merge, push, or discard.

## Bundles

- **Meaning**: newest bundle age against unpushed commits. WARN when the newest bundle is 24 hours old or older while anything is unpushed.
- **First safe action**: bundle the branches named in the Git section. List of bundles older than 30 days is a cleanup candidate list only; the human deletes.
