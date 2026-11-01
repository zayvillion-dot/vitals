# Interpreting the vitals report

The script is read-only. Every fix below is a step for the human; the agent proposes it as What / Where / How and does not run it.

## Disk

- **Meaning**: free space and percent used on the data volume, plus the size of Caches, Trash, and the Claude scratchpad root.
- **Why these thresholds**: below 30 GB free (or over 85% used) APFS purgeable space, git packs, and build output start to collide; below 15 GB (or over 92%) writes fail in odd ways.
- **First safe action**: report the three size lines and name the largest. Do not delete.
- **Escalate**: any RED, or Caches/Trash/scratchpad at 10 GB or more. The human chooses what goes (empty Trash, clear scratchpad dirs, prune old worktrees after bundling).
- A `du timed out` line means the directory is large or slow; treat as a hint, not a number.

## Memory and swap

- **Meaning**: percent of RAM free (macOS `memory_pressure`), swap used against swap allocated, cumulative pageouts.
- **Swap and uptime**: macOS grows swap over time and rarely gives it back until reboot. A long uptime with swap over 50% is usually accumulated pressure, not a one-off spike. Fix order: quit the top processes, then reboot when convenient.
- **Why these thresholds**: free under 30% or swap over 50% means paging has started to show up in latency; under 15% or over 75% tests and builds time out.
- **First safe action**: read the top-memory lines and name the heaviest. Count of `claude`, `node`, `python`, and `Code Helper` processes shows runaway sessions or watchers.
- **Escalate**: RED, or uptime over 7 days with swap WARN. The human quits apps or reboots.

## CPU, thermal, uptime

- **Meaning**: 1/5/15-minute load against core count; `CPU_Speed_Limit` below 100 means thermal throttling.
- **Why**: load above the core count means a run queue; above twice the core count the machine is saturated.
- **First safe action**: check the top-CPU lines. A daemon such as `bird` (iCloud) pinned high usually points to a sync backlog (see below).
- **Escalate**: sustained RED load, or throttling. The human closes workloads or lets the machine cool.

## iCloud and dataless files

- **Meaning**: "dataless" files are iCloud placeholders whose bytes are not on disk. Any read blocks on a download and may fail or hang. Symptoms: tests fail with odd file-read errors, `git status` hangs, builds stall.
- **Detection**: `ls -lO` shows a `dataless` flag. The script counts it for tracked files and for `.git/objects`. It never reads file contents. `find -flags +dataless` is invalid on macOS; do not use it.
- **Recovery recipe** (human runs it):
  1. WHAT: materialise evicted tracked files. WHERE: Terminal in the repo. HOW: `git ls-files -z | xargs -0 -I{} brctl download "$PWD/{}"` (absolute paths only; relative paths are ignored). Or `brctl download "<repo abs path>"` for the whole directory.
  2. Re-run `vitals.sh`; the count should fall to 0. Large trees take minutes; check again.
  3. If `brctl status` shows `blocked` or `SYNC DISABLED` for a real container, sync itself is stopped: sign in again under System Settings > Apple ID > iCloud. Zones for uninstalled apps are expected and ignored.
- **Stale `index.lock` plus hung git**: a killed git leaves `.git/index.lock`. First confirm no git process is alive (the Git section lists any older than 10 minutes). Only then does the human remove the lock file named in the report.
- **`pkill -x cat` hazard**: a process stuck reading an evicted file shows up as `cat` or `git` in uninterruptible I/O. Killing it does not clear the cause and can corrupt an in-flight write. Materialise the files first; kill only with the human's say-so.
- **Escalate**: always. Materialising is the human's call because it downloads data and can fill the disk.

## Git health

- **Meaning**: branch and dirty count per repo and worktree, stale locks, hung git processes, unpushed commits per local branch, no-upstream branches, broken ref names.
- **Why**: unpushed work exists only on this disk; the 2026-09-25 loss was a branch that never left it. A branch with no upstream is unpushed by definition; the report counts commits not on any remote.
- **First safe action**: bundle every unpushed branch: `git bundle create <bundles-dir>/<name>.bundle <branch>`. The human pushes.
- **Broken ref names** (for example `origin/name 2`) are Finder duplicates inside `.git/refs`. They make `rev-list --remotes` fail. Bundle first, then the human removes them.
- **`git status hung`**: almost always dataless files in that worktree. Run the iCloud recipe against that path.

## Worktrees

- **Meaning**: count and age of worktrees, plus strays: loose directories, `*.bundle` files, Finder duplicates (`name 2`).
- **Why**: more than 8 worktrees multiplies iCloud sync load and unpushed risk; stale ones hold unmerged work nobody remembers.
- **Hygiene rule**: bundle every branch before deleting a worktree, confirm the bundle verifies (`git bundle verify`), then the human removes the worktree. Move bundles out of the worktrees directory so they stop reading as strays.
- **Escalate**: stale worktrees with unpushed commits. The human decides merge, push, or discard.

## Bundles

- **Meaning**: newest bundle age against unpushed commits. WARN when the newest bundle is 24 hours old or older while anything is unpushed.
- **First safe action**: bundle the branches named in the Git section. List of bundles older than 30 days is a cleanup candidate list only; the human deletes.
