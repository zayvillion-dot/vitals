#!/usr/bin/env bash
# vitals.sh - one-shot, read-only health snapshot of the dev machine and its git repos.
# Never deletes, kills (other than its own timed-out probe children), or modifies anything.
# On iCloud paths it counts dataless (evicted) files with stat-only `ls -lO` BEFORE any git call that
# reads file contents, and skips those calls when the count is not a confirmed zero, so it never
# triggers a download.
# macOS first; degrades to n/a or Linux equivalents. No `set -e`: a failing probe must not kill the report.
set -u
export LC_ALL=C
export GIT_OPTIONAL_LOCKS=0   # git status must not refresh/write the index
VERSION="0.1.0"
GT="${VITALS_GIT_TIMEOUT:-5}"   # seconds per git call / dataless count
case "$GT" in ''|*[!0-9]*) GT=5 ;; esac; [ "$GT" -ge 1 ] || GT=1
BUDGET=25                       # whole-run wall-clock budget; probes still pending after it are skipped
SECONDS=0

usage() {
  cat <<'USAGE'
Usage: vitals.sh [--repo <path>]... [--worktrees <dir>]... [--bundles <dir>] [--json] [--quick]
  --repo <path>       git repo to check (repeatable). Default: cwd's git toplevel.
  --worktrees <dir>   worktrees directory to scan (repeatable). Default: *-worktrees directories beside
                      the repo. Linked worktrees from `git worktree list` are always added (not with --quick).
  --bundles <dir>     directory of git bundles. Default: ~/nle-bundles if it exists.
  --json              emit JSON instead of text.
  --quick             skip du, brctl status, linked worktrees and worktree scans. Repos still get the
                      dataless count before git status, so allow up to one git timeout per repo.
Env: VITALS_REPOS, VITALS_WORKTREES, VITALS_BUNDLES (colon-separated) apply when the flag is absent.
     VITALS_GIT_TIMEOUT  seconds per git call and dataless count (default 5). Whole run capped at 25 s.
USAGE
}

REPOS_IN=""; WT_IN=""; BUNDLES_IN=""; JSON=0; QUICK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      [ $# -ge 2 ] || { usage >&2; exit 2; }; REPOS_IN="$REPOS_IN$2"$'\n'; shift 2 ;;
    --worktrees) [ $# -ge 2 ] || { usage >&2; exit 2; }; WT_IN="$WT_IN$2"$'\n'; shift 2 ;;
    --bundles)   [ $# -ge 2 ] || { usage >&2; exit 2; }; BUNDLES_IN="$2"; shift 2 ;;
    --json)  JSON=1; shift ;;
    --quick) QUICK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "vitals: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -z "$REPOS_IN" ] && [ -n "${VITALS_REPOS:-}" ] && REPOS_IN=$(printf '%s' "$VITALS_REPOS" | tr ':' '\n')
[ -z "$WT_IN" ] && [ -n "${VITALS_WORKTREES:-}" ] && WT_IN=$(printf '%s' "$VITALS_WORKTREES" | tr ':' '\n')
[ -z "$BUNDLES_IN" ] && [ -n "${VITALS_BUNDLES:-}" ] && BUNDLES_IN="$VITALS_BUNDLES"

OS=$(uname -s); MAC=0; [ "$OS" = "Darwin" ] && MAC=1
NOW=$(date +%s)
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/vitals.XXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT
REC="$TMPD/records"; : > "$REC"
NRED=0; NWARN=0; CUR_SEC=""
SKIPMSG="skipped: run budget exceeded"

have() { command -v "$1" >/dev/null 2>&1; }

# killtree PID: SIGKILL a probe child and its descendants. Only ever called on this script's own probes.
killtree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done; kill -9 "$1" 2>/dev/null; }

# await PID SECS: poll (never block in `wait`) until PID exits, SECS pass, or the run budget runs out.
# Returns the child's status, 124 if it outlived SECS, 125 if it outlived the run budget.
# A child wedged in uninterruptible iCloud I/O ignores signals; polling lets us abandon it.
await() {
  local pid=$1 secs=$2 rem t=0 lim rc=124
  rem=$((BUDGET - SECONDS))
  if [ "$rem" -lt "$secs" ]; then secs=$rem; rc=125; fi
  [ "$secs" -lt 0 ] && secs=0
  lim=$((secs*5))
  while kill -0 "$pid" 2>/dev/null; do
    [ "$t" -ge "$lim" ] && return $rc
    sleep 0.2; t=$((t+1))
  done
  wait "$pid" 2>/dev/null   # already exited: reaps without blocking
}

# to SECS CMD...: run CMD (a command or shell function) with a wall-clock limit, clamped to the run budget.
# Polling only (no GNU timeout, which waits for its child). Callers redirect output to a file, not $(...),
# so an abandoned child cannot hold a pipe open. 124 = timed out, 125 = run budget exhausted.
to() {
  local secs=$1 pid rc; shift
  [ $((BUDGET - SECONDS)) -gt 0 ] || return 125
  "$@" </dev/null &
  pid=$!
  await "$pid" "$secs"; rc=$?
  if [ "$rc" -ge 124 ] && kill -0 "$pid" 2>/dev/null; then killtree "$pid"; return $rc; fi
  return $rc
}

sec() { CUR_SEC="$1"; }
emit() { # tag metric [threshold] [priority: 1 = dataless/hung git/stale lock; default by section]
  local tag=$1 metric=$2 thr=${3:-} pr=${4:-}
  metric=$(printf '%s' "$metric" | tr '\t\n' '  ')
  if [ -z "$pr" ]; then case "$CUR_SEC" in Disk) pr=2 ;; Memory) pr=3 ;; *) pr=4 ;; esac; fi
  case "$tag" in RED) NRED=$((NRED+1)) ;; WARN) NWARN=$((NWARN+1)) ;; esac
  # priority first: tab is IFS whitespace, so an empty field collapses; only the last (threshold) may be empty
  printf '%s\t%s\t%s\t%s\t%s\n' "$pr" "$CUR_SEC" "$tag" "$metric" "$thr" >> "$REC"
}

abspath() { ( cd "$1" 2>/dev/null && pwd -P ); }
mtime() { if [ "$MAC" = 1 ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi; }
kv() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }
AWK_DL='$5 ~ /dataless/ {c++} END{print c+0}'
AWK_ETIME='function sec(e,  d,a,n,s,x,i){d=0; if(index(e,"-")){split(e,x,"-"); d=x[1]; e=x[2]} n=split(e,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; return d*86400+s}'

icloud_path() {
  case "$1" in
    */Library/Mobile\ Documents/*|"$HOME"/Documents|"$HOME"/Documents/*|"$HOME"/Desktop|"$HOME"/Desktop/*) return 0 ;;
  esac
  return 1
}

# ---------- resolve targets ----------
TG="$TMPD/targets"; : > "$TG"          # kind|path   (R = explicit repo, W = linked worktree)
BAD_REPOS=""; SLOW_REPOS=""
add_target() { grep -q "^[RW]|$(printf '%s' "$2" | sed 's/[][\.*^$/]/\\&/g')\$" "$TG" 2>/dev/null || echo "$1|$2" >> "$TG"; }

if [ -z "$REPOS_IN" ]; then
  to "$GT" git rev-parse --show-toplevel > "$TMPD/top" 2>/dev/null
  top=$(head -1 "$TMPD/top"); [ -n "$top" ] && REPOS_IN="$top"$'\n'
fi
REPO_LIST=""
while IFS= read -r r; do
  [ -z "$r" ] && continue
  to "$GT" git -C "$r" rev-parse --show-toplevel > "$TMPD/top" 2>/dev/null; rc=$?
  top=$(head -1 "$TMPD/top")
  if [ "$rc" -ge 124 ]; then SLOW_REPOS="$SLOW_REPOS$r"$'\n'; continue; fi
  if [ -z "$top" ]; then BAD_REPOS="$BAD_REPOS$r"$'\n'; continue; fi
  top=$(abspath "$top")
  add_target R "$top"
  REPO_LIST="$REPO_LIST$top"$'\n'
done <<< "$REPOS_IN"

WTDIRS=""
if [ -n "$WT_IN" ]; then WTDIRS="$WT_IN"; else
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    par=$(dirname "$r")
    for d in "$par"/*-worktrees; do [ -d "$d" ] && WTDIRS="$WTDIRS$d"$'\n'; done
  done <<< "$REPO_LIST"
fi
WTDIRS=$(printf '%s' "$WTDIRS" | awk 'NF && !s[$0]++')

if [ "$QUICK" = 0 ]; then
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    to "$GT" git -C "$r" worktree list --porcelain > "$TMPD/wtp" 2>/dev/null
    awk '/^worktree /{n++; if(n>1) print substr($0,10)}' "$TMPD/wtp" | while IFS= read -r w; do
      [ -d "$w" ] && abspath "$w"
    done > "$TMPD/wtl"
    while IFS= read -r w; do [ -n "$w" ] && add_target W "$w"; done < "$TMPD/wtl"
  done <<< "$REPO_LIST"
  while IFS= read -r d; do
    [ -z "$d" ] || [ ! -d "$d" ] && continue
    for e in "$d"/*; do
      [ -d "$e" ] && [ -e "$e/.git" ] && add_target W "$(abspath "$e")"
    done
  done <<< "$WTDIRS"
fi

BUNDLES_DIR=""
if [ -n "$BUNDLES_IN" ]; then BUNDLES_DIR="$BUNDLES_IN"; elif [ -d "$HOME/nle-bundles" ]; then BUNDLES_DIR="$HOME/nle-bundles"; fi

# ---------- background probes ----------
# Every background probe gets stdout/stderr on /dev/null so an abandoned child never holds the caller's pipe.
ICL_NEEDED=0
if [ "$MAC" = 1 ]; then
  while IFS='|' read -r kind p; do icloud_path "$p" && ICL_NEEDED=1; done < "$TG"
fi
BRCTL_PID=""
if [ "$QUICK" = 0 ] && [ "$ICL_NEEDED" = 1 ] && have brctl; then
  # brctl status can run for minutes; stream through sed and keep whatever arrives in 4 s.
  ( to 4 sh -c "brctl status 2>&1 | sed 's/\\x1b\\[[0-9;]*m//g' > '$TMPD/brctl.out'" ) >/dev/null 2>&1 &
  BRCTL_PID=$!
fi

DU_T=10
SCRATCH="/private/tmp/claude-$(id -u)"; [ -d "$SCRATCH" ] || SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
if [ "$QUICK" = 0 ]; then
  n=0
  for p in "$HOME/Library/Caches" "$HOME/.Trash" "$SCRATCH"; do
    n=$((n+1))
    [ -d "$p" ] || continue
    # -d0 is the portable spelling of -s (BSD du rejects -s together with -d). Stat-only, one filesystem.
    ( to "$DU_T" du -xk -d0 "$p" > "$TMPD/du.$n" 2>/dev/null; echo $? > "$TMPD/du.$n.rc" ) >/dev/null 2>&1 &
    eval "DU_PID_$n=$!"
  done
fi

# metaprobe PATH ICLOUD: locate the git dirs without running git. On iCloud paths, stat the .git file and
# the per-worktree git dir listing (HEAD, index, commondir) before reading any of them.
metaprobe() {
  local p=$1 icl=$2 g c n
  if [ -d "$p/.git" ]; then g="$p/.git"
  elif [ -f "$p/.git" ]; then
    if [ "$icl" = 1 ]; then n=$(ls -lO "$p/.git" 2>/dev/null | awk "$AWK_DL"); [ "${n:-0}" -gt 0 ] && { echo "meta_dl=$n"; return 0; }; fi
    g=$(sed -n 's/^gitdir: //p' "$p/.git" 2>/dev/null | head -1)
    [ -n "$g" ] || return 0
    case "$g" in /*) ;; *) g="$p/$g" ;; esac
  else return 0; fi
  if [ "$icl" = 1 ]; then n=$(ls -lO "$g" 2>/dev/null | awk "$AWK_DL"); [ "${n:-0}" -gt 0 ] && { echo "meta_dl=$n"; return 0; }; fi
  c="$g"
  if [ -f "$g/commondir" ]; then c=$(head -1 "$g/commondir"); case "$c" in /*) ;; *) c="$g/$c" ;; esac; fi
  echo "meta_dl=0"
  echo "gdir=$g"
  echo "cdir=$(abspath "$c")"
  echo "headref=$(head -1 "$g/HEAD" 2>/dev/null)"
}
tracked_dl() { cd "$1" && git ls-files -z | xargs -0 ls -lO 2>/dev/null | awk "$AWK_DL"; }
gitdir_dl() { { ls -lO "$1"; find "$1/refs" "$1/objects" -type f -exec ls -lO {} + ; } 2>/dev/null | awk "$AWK_DL"; }
key() { printf '%s' "$1" | cksum | awk '{print $1}'; }

RCDIRS="$TMPD/rcdirs"; : > "$RCDIRS"   # common dirs owned by an explicit repo: its probe reports branches
while IFS='|' read -r kind p; do [ "$kind" = R ] && [ -d "$p/.git" ] && abspath "$p/.git" >> "$RCDIRS"; done < "$TG"

# gprobe IDX KIND PATH ICLOUD: writes key=value lines to $TMPD/g.IDX, ending with done=1.
gprobe() {
  local i=$1 kind=$2 p=$3 icl=$4 f="$TMPD/g.$i" rc lock cdir hr nt ng k lim tot dowork b up tr_ n cnt
  : > "$f"
  {
    echo "path=$p"; echo "kind=$kind"; echo "icl=$icl"
    to "$GT" metaprobe "$p" "$icl" > "$TMPD/m.$i" 2>/dev/null; rc=$?
    if [ "$rc" -ge 124 ]; then
      [ "$rc" = 125 ] && echo "state=budget" || echo "state=incomplete"
      echo "done=1"; return
    fi
    cat "$TMPD/m.$i"
    if [ "$(kv "$TMPD/m.$i" meta_dl)" != 0 ] && [ -n "$(kv "$TMPD/m.$i" meta_dl)" ]; then
      echo "dl=$(kv "$TMPD/m.$i" meta_dl)"; echo "dl_where=git metadata"; echo "state=dataless"; echo "done=1"; return
    fi
    cdir=$(kv "$TMPD/m.$i" cdir); hr=$(kv "$TMPD/m.$i" headref)
    case "$hr" in "ref: refs/heads/"*) echo "branch=${hr#ref: refs/heads/}" ;; *) echo "branch=detached" ;; esac
    lock=""; [ -n "$(kv "$TMPD/m.$i" gdir)" ] && lock="$(kv "$TMPD/m.$i" gdir)/index.lock"
    if [ -n "$lock" ] && [ -e "$lock" ]; then echo "lock=$lock"; echo "lockmtime=$(mtime "$lock")"; fi

    dowork=1
    if [ "$icl" = 1 ]; then
      to "$GT" tracked_dl "$p" > "$TMPD/dt.$i" 2>/dev/null; rc=$?
      if [ "$rc" -ge 124 ]; then nt=$rc; else nt=$(tr -d ' \n' < "$TMPD/dt.$i"); fi
      ng=0
      if [ -n "$cdir" ] && icloud_path "$cdir"; then
        k=$(key "$cdir")
        if mkdir "$TMPD/gd.$k" 2>/dev/null; then
          to "$GT" gitdir_dl "$cdir" > "$TMPD/gd.$k/out" 2>/dev/null; echo $? > "$TMPD/gd.$k/rc.tmp"; mv "$TMPD/gd.$k/rc.tmp" "$TMPD/gd.$k/rc"
        else
          lim=$((SECONDS + GT + 2))
          while [ ! -f "$TMPD/gd.$k/rc" ] && [ "$SECONDS" -lt "$lim" ] && [ "$SECONDS" -lt "$BUDGET" ]; do sleep 0.2; done
        fi
        rc=$(cat "$TMPD/gd.$k/rc" 2>/dev/null); [ -z "$rc" ] && { [ "$SECONDS" -ge "$BUDGET" ] && rc=125 || rc=124; }
        if [ "$rc" -ge 124 ]; then ng=$rc; else ng=$(tr -d ' \n' < "$TMPD/gd.$k/out"); fi
      fi
      if [ "$nt" = 125 ] || [ "$ng" = 125 ]; then echo "state=budget"; echo "done=1"; return; fi
      if [ "$nt" = 124 ] || [ "$ng" = 124 ]; then echo "state=incomplete"; echo "done=1"; return; fi
      tot=$(( ${nt:-0} + ${ng:-0} ))
      echo "dl_tracked=${nt:-0}"; echo "dl_gitdir=${ng:-0}"
      if [ "$tot" -gt 0 ]; then
        echo "dl=$tot"; echo "state=dataless"; dowork=0
      fi
    fi

    if [ "$dowork" = 1 ]; then
      to "$GT" git -C "$p" status --porcelain > "$TMPD/s.$i" 2>/dev/null; rc=$?
      case "$rc" in
        0)   echo "state=ok"; echo "dirty=$(wc -l < "$TMPD/s.$i" | tr -d ' ')" ;;
        124) echo "state=hung" ;;
        125) echo "state=budget"; echo "done=1"; return ;;
        *)   echo "state=failed"; echo "status_rc=$rc" ;;
      esac
      if [ "$kind" = W ]; then
        to "$GT" git -C "$p" log -1 --format=%ct > "$TMPD/ct.$i" 2>/dev/null && echo "ct=$(tr -d ' \n' < "$TMPD/ct.$i")"
      fi
      # Branch probe once per common dir: the explicit repo owns it; otherwise the first worktree to claim it.
      if [ -n "$cdir" ]; then
        if [ "$kind" = R ] || { ! grep -Fxq "$cdir" "$RCDIRS" && mkdir "$TMPD/br.$(key "$cdir")" 2>/dev/null; }; then
          to "$GT" git -C "$p" for-each-ref --format='%(refname:short)|%(upstream:short)|%(upstream:track)' refs/heads > "$TMPD/fe.$i" 2> "$TMPD/fe.err.$i"; rc=$?
          if [ "$rc" = 0 ]; then
            echo "broken_refs=$(grep -c 'broken name' "$TMPD/fe.err.$i")"
            cnt=0
            while IFS='|' read -r b up tr_; do
              [ -z "$b" ] && continue
              if [ -n "$up" ] && [ "$tr_" != "[gone]" ]; then
                n=$(printf '%s' "$tr_" | sed -n 's/.*ahead \([0-9]*\).*/\1/p'); echo "A|$b|${n:-0}"
              else
                cnt=$((cnt+1))
                if [ "$cnt" -le 40 ]; then
                  to "$GT" git -C "$p" rev-list --count "refs/heads/$b" --not --remotes > "$TMPD/rl.$i" 2>/dev/null \
                    && n=$(tr -d ' \n' < "$TMPD/rl.$i") || n="?"
                  echo "N|$b|${n:-?}"
                else echo "N|$b|?"; fi
              fi
            done < "$TMPD/fe.$i" > "$TMPD/b.$i"
          else
            echo "branches=unavailable"
          fi
        fi
      fi
    fi
    echo "done=1"
  } >> "$f" 2>/dev/null
}
i=0
while IFS='|' read -r kind p; do
  [ -z "$p" ] && continue
  i=$((i+1))
  icl=0; [ "$MAC" = 1 ] && icloud_path "$p" && icl=1
  gprobe "$i" "$kind" "$p" "$icl" >/dev/null 2>&1 &
  eval "GPID_$i=$!"
  printf '%s\t%s\n' "$p" "$i" >> "$TMPD/pathidx"
done < "$TG"
NTARGETS=$i

# ---------- Disk ----------
sec "Disk"
DFP="/"; [ "$MAC" = 1 ] && [ -d /System/Volumes/Data ] && DFP="/System/Volumes/Data"
read -r dtotal davail < <(df -Pk "$DFP" 2>/dev/null | awk 'NR==2{print $2, $4}')
if [ -n "${dtotal:-}" ] && [ "${dtotal:-0}" -gt 0 ] 2>/dev/null; then
  freegb=$(awk -v a="$davail" 'BEGIN{printf "%.1f", a/1048576}')
  usedpct=$(awk -v t="$dtotal" -v a="$davail" 'BEGIN{printf "%.0f", (t-a)*100/t}')
  tag=OK
  awk -v g="$freegb" -v u="$usedpct" 'BEGIN{exit !(g<30 || u>85)}' && tag=WARN
  awk -v g="$freegb" -v u="$usedpct" 'BEGIN{exit !(g<15 || u>92)}' && tag=RED
  emit "$tag" "$DFP: ${freegb} GiB free, ${usedpct}% used" "WARN <30 GiB or >85% used; RED <15 GiB or >92%"
else
  emit "n/a" "df unavailable for $DFP"
fi
if [ "$QUICK" = 0 ]; then
  n=0
  for p in "$HOME/Library/Caches" "$HOME/.Trash" "$SCRATCH"; do
    n=$((n+1))
    label=$(printf '%s' "$p" | sed "s|^$HOME|~|")
    if [ ! -d "$p" ]; then emit "n/a" "$label: not present"; continue; fi
    eval "dp=\${DU_PID_$n:-}"
    [ -n "$dp" ] && await "$dp" $((DU_T + 1))
    rc=$(cat "$TMPD/du.$n.rc" 2>/dev/null)
    kb=$(cut -f1 "$TMPD/du.$n" 2>/dev/null | head -1)
    if [ "$rc" = 125 ] || { [ -z "$rc" ] && [ "$SECONDS" -ge "$BUDGET" ]; }; then emit "n/a" "$label: $SKIPMSG"; continue; fi
    case "$kb" in ''|*[!0-9]*) emit "n/a" "$label: size unknown (>${DU_T} s)" "${DU_T} s limit"; continue ;; esac
    sz=$(awk -v k="$kb" 'BEGIN{ if(k>=1048576) printf "%.1f GiB", k/1048576; else printf "%.0f MiB", k/1024 }')
    tag=OK; [ "$kb" -ge 10485760 ] && tag=WARN
    emit "$tag" "$label: $sz" "WARN >= 10 GiB"
  done
else
  emit "n/a" "Caches/Trash/scratchpad sizes skipped (--quick)"
fi

# ---------- Memory ----------
sec "Memory"
SWAP_THR="WARN used >25% of RAM; RED >50%"
swapgrade() { # used_mb ram_mb -> sets SWPCT and tag
  SWPCT=$(awk -v u="$1" -v r="$2" 'BEGIN{ if(r>0) printf "%.0f", u*100/r; else print 0 }')
  tag=OK; [ "$SWPCT" -gt 25 ] && tag=WARN; [ "$SWPCT" -gt 50 ] && tag=RED
}
if [ "$MAC" = 1 ]; then
  memb=$(sysctl -n hw.memsize 2>/dev/null); memgb=$(awk -v b="${memb:-0}" 'BEGIN{printf "%.0f", b/1073741824}')
  to 5 memory_pressure > "$TMPD/mp" 2>/dev/null
  freepct=$(awk -F': ' '/System-wide memory free percentage/{gsub(/%/,"",$2); print $2+0}' "$TMPD/mp")
  if [ -n "$freepct" ]; then
    tag=OK; [ "$freepct" -lt 30 ] && tag=WARN; [ "$freepct" -lt 15 ] && tag=RED
    emit "$tag" "${memgb} GB physical, ${freepct}% free" "WARN <30% free; RED <15%"
  else
    emit "n/a" "${memgb} GB physical; memory_pressure unavailable"
  fi
  sw=$(sysctl -n vm.swapusage 2>/dev/null)
  if [ -n "$sw" ]; then
    set -- $(printf '%s' "$sw" | awk '{
      for(i=1;i<=NF;i++){ if($i=="total"||$i=="used"){v=$(i+2); u=substr(v,length(v)); n=substr(v,1,length(v)-1)+0; if(u=="G")n*=1024; else if(u=="K")n/=1024; print n} } }')
    swt=${1:-0}; swu=${2:-0}
    rammb=$(awk -v b="${memb:-0}" 'BEGIN{printf "%.0f", b/1048576}')
    swapgrade "$swu" "$rammb"
    emit "$tag" "swap used $(awk -v u="$swu" 'BEGIN{printf "%.1f", u/1024}') GB (${SWPCT}% of ${memgb} GB RAM); allocated $(awk -v t="$swt" 'BEGIN{printf "%.1f", t/1024}') GB (info)" "$SWAP_THR"
  else emit "n/a" "swap: sysctl vm.swapusage unavailable"; fi
  po=$(vm_stat 2>/dev/null | awk '/^Pageouts:/{gsub(/\./,"",$2); print $2}')
  [ -n "$po" ] && emit "OK" "pageouts since boot: $po pages" "info only" || emit "n/a" "pageouts unavailable"
elif [ -r /proc/meminfo ]; then
  mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo); ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  st=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo); sf=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
  freepct=$(awk -v a="${ma:-0}" -v t="${mt:-1}" 'BEGIN{printf "%d", a*100/t}')
  memgb=$(awk -v t="${mt:-0}" 'BEGIN{printf "%.0f", t/1048576}')
  tag=OK; [ "$freepct" -lt 30 ] && tag=WARN; [ "$freepct" -lt 15 ] && tag=RED
  emit "$tag" "${memgb} GB physical, ${freepct}% available" "WARN <30% free; RED <15%"
  swu=$(awk -v t="${st:-0}" -v f="${sf:-0}" 'BEGIN{printf "%.0f", (t-f)/1024}')
  swapgrade "$swu" "$(awk -v t="${mt:-0}" 'BEGIN{printf "%.0f", t/1024}')"
  emit "$tag" "swap used $(awk -v u="$swu" 'BEGIN{printf "%.1f", u/1024}') GB (${SWPCT}% of ${memgb} GB RAM); allocated $(awk -v t="${st:-0}" 'BEGIN{printf "%.1f", t/1048576}') GB (info)" "$SWAP_THR"
  po=$(awk '/^pswpout /{print $2}' /proc/vmstat 2>/dev/null)
  [ -n "$po" ] && emit "OK" "pages swapped out since boot: $po" "info only" || emit "n/a" "pageouts unavailable"
else
  emit "n/a" "memory probes unavailable on $OS"
fi

# ---------- CPU / load ----------
sec "CPU"
if [ "$MAC" = 1 ]; then cores=$(sysctl -n hw.ncpu 2>/dev/null); else cores=$(nproc 2>/dev/null); fi
cores=${cores:-1}
loads=$(uptime | sed -e 's/.*load averages*: *//' -e 's/,/ /g')
set -- $loads; l1=${1:-0}; l5=${2:-0}; l15=${3:-0}
tag=OK
awk -v l="$l1" -v c="$cores" 'BEGIN{exit !(l>c)}' && tag=WARN
awk -v l="$l1" -v c="$cores" 'BEGIN{exit !(l>2*c)}' && tag=RED
emit "$tag" "load $l1 / $l5 / $l15 (1/5/15 min) on $cores cores" "WARN 1-min load > cores; RED > 2x cores"
if [ "$MAC" = 1 ] && have pmset; then
  lim=$(pmset -g therm 2>/dev/null | awk -F= '/CPU_Speed_Limit/{gsub(/ /,"",$2); print $2}')
  if [ -n "$lim" ] && [ "$lim" -lt 100 ] 2>/dev/null; then emit WARN "thermal throttling: CPU_Speed_Limit=$lim" "WARN <100"
  else emit OK "no thermal throttling (CPU_Speed_Limit=${lim:-100})" "WARN <100"; fi
else emit "n/a" "thermal: pmset unavailable"; fi
if [ "$MAC" = 1 ]; then
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p'); upsec=$((NOW - ${boot:-$NOW}))
elif [ -r /proc/uptime ]; then upsec=$(awk '{printf "%d", $1}' /proc/uptime); else upsec=""; fi
if [ -n "$upsec" ]; then
  days=$((upsec/86400))
  if [ "$days" -gt 7 ]; then emit WARN "uptime ${days} days: long uptime, swap accumulates" "WARN >7 days"
  else emit OK "uptime ${days} days" "WARN >7 days"; fi
else emit "n/a" "uptime unavailable"; fi

# ---------- Top processes ----------
sec "Processes"
if [ "$MAC" = 1 ]; then
  PS_M=$(ps -Ao pid,pcpu,pmem,rss,etime,comm -m 2>/dev/null | sed -n 2,6p)
  PS_C=$(ps -Ao pid,pcpu,pmem,rss,etime,comm -r 2>/dev/null | sed -n 2,4p)
else
  PS_M=$(ps -Ao pid,pcpu,pmem,rss,etime,comm --sort=-rss 2>/dev/null | sed -n 2,6p)
  PS_C=$(ps -Ao pid,pcpu,pmem,rss,etime,comm --sort=-pcpu 2>/dev/null | sed -n 2,4p)
fi
fmtps() { awk '{ nm=$6; for(i=7;i<=NF;i++) nm=nm" "$i; sub(/^.*\//,"",nm); printf "%s|%s|%s\n", $3, sprintf("%s pid %s cpu %s%% mem %s%% rss %d MB up %s", nm, $1, $2, $3, $4/1024, $5), "" }'; }
while IFS='|' read -r pm line _; do
  [ -z "$line" ] && continue
  tag=OK; awk -v p="$pm" 'BEGIN{exit !(p>25)}' && tag=WARN
  emit "$tag" "top mem: $line" "WARN single process >25% RAM"
done < <(printf '%s\n' "$PS_M" | fmtps)
while IFS='|' read -r pm line _; do
  [ -z "$line" ] && continue
  emit OK "top cpu: $line" "info only"
done < <(printf '%s\n' "$PS_C" | fmtps)
PSC=$(ps -Ao comm= 2>/dev/null | awk '{sub(/^.*\//,""); print tolower($0)}')
cnt() { printf '%s\n' "$PSC" | awk -v pat="$1" -v mode="$2" '{ if(mode=="eq" ? $0==pat : index($0,pat)==1 ) c++ } END{print c+0}'; }
emit OK "process counts: claude $(cnt claude eq), node $(cnt node eq), python $(cnt python pre), Code Helper $(printf '%s\n' "$PSC" | grep -c 'code helper')" "info only"

# ---------- wait for git probes (bounded by the run budget) ----------
i=0
while [ "$i" -lt "$NTARGETS" ]; do
  i=$((i+1)); eval "gp=\${GPID_$i:-}"
  [ -n "$gp" ] || continue
  await "$gp" "$BUDGET"
  if kill -0 "$gp" 2>/dev/null; then killtree "$gp"; fi
done
# state of probe i: ok|hung|failed|dataless|incomplete|budget  (budget also when the probe never finished)
pstate() { local f="$TMPD/g.$1"; if [ "$(kv "$f" done)" = 1 ]; then kv "$f" state; else echo budget; fi; }

# ---------- iCloud / dataless ----------
sec "iCloud"
if [ "$MAC" != 1 ]; then emit "n/a" "iCloud dataless probes are macOS-only"
elif [ "$ICL_NEEDED" = 0 ]; then emit "n/a" "no target under ~/Documents, ~/Desktop or ~/Library/Mobile Documents"
else
  if [ "$QUICK" = 1 ]; then emit "n/a" "brctl status skipped (--quick)"
  elif ! have brctl; then emit "n/a" "brctl not found"
  else
    [ -n "$BRCTL_PID" ] && await "$BRCTL_PID" 6
    if [ ! -s "$TMPD/brctl.out" ]; then
      emit "n/a" "brctl status returned nothing in 4 s (iCloud Desktop & Documents may be off)"
    else
      nlines=$(wc -l < "$TMPD/brctl.out" | tr -d ' ')
      nsd=$(grep -i 'SYNC DISABLED' "$TMPD/brctl.out" | grep -vic 'app not installed')
      nbl=$(grep -i 'blocked' "$TMPD/brctl.out" | grep -vi -e 'blocked-app-uninstalled' -e 'app not installed' -e 'SYNC DISABLED' | wc -l | tr -d ' ')
      if [ "$nsd" -gt 0 ] || [ "$nbl" -gt 0 ]; then
        emit RED "brctl status: $nsd SYNC DISABLED + $nbl blocked entries (excluding uninstalled apps), first $nlines lines scanned" "RED any blocked / SYNC DISABLED"
      else
        emit OK "brctl status: no blocked / SYNC DISABLED zones in first $nlines lines (4 s partial scan; uninstalled-app zones ignored)" "RED any blocked / SYNC DISABLED"
      fi
    fi
  fi
  nc=0; nd=0; ni=0; ns=0; i=0
  while IFS='|' read -r kind p; do
    [ -z "$p" ] && continue; i=$((i+1))
    [ "$(kv "$TMPD/g.$i" icl)" = 1 ] || continue
    case "$(pstate "$i")" in dataless) nd=$((nd+1)) ;; incomplete) ni=$((ni+1)) ;; budget) ns=$((ns+1)) ;; *) nc=$((nc+1)) ;; esac
  done < "$TG"
  emit OK "stat-only dataless count on $((nc+nd+ni+ns)) iCloud targets: $nc clean, $nd with dataless files, $ni incomplete, $ns skipped (budget); per-target lines in Git" "git status runs only on a confirmed zero count"
fi

# ---------- Git health ----------
sec "Git"
while IFS= read -r r; do [ -n "$r" ] && emit WARN "not a git repo: $r" "path given via --repo"; done <<< "$BAD_REPOS"
while IFS= read -r r; do [ -n "$r" ] && emit RED "git rev-parse slow or blocked (>${GT} s): $r" "RED > ${GT} s" 1; done <<< "$SLOW_REPOS"
HG=$(ps -Ao pid=,etime=,comm= 2>/dev/null | awk "$AWK_ETIME"'{ nm=$3; for(i=4;i<=NF;i++) nm=nm" "$i; sub(/^.*\//,"",nm); if(nm=="git" && sec($2)>600) printf "pid %s (%s) ", $1, $2 }')
if [ -n "$HG" ]; then emit WARN "hung git processes (>10 min): $HG" "WARN git older than 10 min"; else emit OK "no git process older than 10 min" "WARN > 10 min"; fi
UNPUSHED=0; i=0
while IFS='|' read -r kind p; do
  [ -z "$p" ] && continue; i=$((i+1)); f="$TMPD/g.$i"; nm=$(basename "$p")
  st=$(pstate "$i")
  case "$st" in
    ok)       emit OK "$nm [$(kv "$f" branch)] ($kind) dirty files: $(kv "$f" dirty)" "info only" ;;
    hung)     emit RED "$nm: git status slow or blocked (>${GT} s): $p" "RED > ${GT} s" 1 ;;
    failed)   emit WARN "$nm: git status failed (rc=$(kv "$f" status_rc)): $p" "WARN non-zero exit" ;;
    dataless)
      dlw=$(kv "$f" dl_where); n=$(kv "$f" dl)
      if [ -n "$dlw" ]; then what="dataless $dlw files"
      else
        what="dataless tracked files"; nt=$(kv "$f" dl_tracked); ng=$(kv "$f" dl_gitdir)
        [ "${ng:-0}" -gt 0 ] && what="dataless files ($nt tracked, $ng in .git)"
      fi
      fix="brctl download \"$p\""
      cdir=$(kv "$f" cdir)
      if [ "${ng:-0}" -gt 0 ] && [ -n "$cdir" ]; then case "$cdir" in "$p"/*) ;; *) fix="$fix; brctl download \"$cdir\"" ;; esac; fi
      emit RED "$nm: status skipped — $n $what; fix: $fix" "RED any dataless" 1 ;;
    incomplete) emit WARN "$nm: dataless count incomplete (>${GT} s); git status skipped" "WARN count timed out" ;;
    *)        emit "n/a" "$nm: $SKIPMSG" ;;
  esac
  lm=$(kv "$f" lockmtime)
  if [ -n "$lm" ]; then
    age=$((NOW - lm))
    [ "$age" -gt 600 ] && emit RED "$nm: stale index.lock ($((age/60)) min old): $(kv "$f" lock)" "RED lock older than 10 min" 1
  fi
  br=$(kv "$f" broken_refs)
  [ "${br:-0}" -gt 0 ] 2>/dev/null && emit WARN "$nm: $br git refs with broken names (Finder duplicates like 'name 2' in .git/refs); human removes after bundling" "WARN any broken ref"
  [ "$(kv "$f" branches)" = unavailable ] && emit "n/a" "$nm: branch list unavailable (git for-each-ref failed or timed out)"
  if [ -f "$TMPD/b.$i" ] && [ "$(kv "$f" done)" = 1 ]; then
    nb=0; na=0; nn=0; nu=0; nolist=""
    while IFS='|' read -r t b n; do
      nb=$((nb+1))
      if [ "$t" = A ]; then
        if [ "${n:-0}" -gt 0 ] 2>/dev/null; then na=$((na+1)); UNPUSHED=$((UNPUSHED+n)); emit WARN "$nm: branch $b has $n unpushed commits" "WARN ahead > 0"; fi
      else
        if [ "$n" = "?" ] || [ "${n:-0}" -gt 0 ] 2>/dev/null; then
          nn=$((nn+1)); [ "$n" != "?" ] && UNPUSHED=$((UNPUSHED+n))
          [ "$nn" -le 6 ] && nolist="$nolist $b(${n} not on any remote)"
        else nu=$((nu+1)); fi
      fi
    done < "$TMPD/b.$i"
    [ "$nn" -gt 0 ] && emit WARN "$nm: $nn local branches with no upstream have commits on no remote (? = count unavailable):$nolist" "WARN no upstream and commits not on any remote"
    [ "$na" -eq 0 ] && [ "$nn" -eq 0 ] && emit OK "$nm: $nb local branches, all commits on a remote ($nu without upstream)" "WARN ahead > 0 or commits on no remote"
  fi
done < "$TG"

# ---------- Worktrees ----------
sec "Worktrees"
if [ "$QUICK" = 1 ]; then emit "n/a" "skipped (--quick)"
elif [ -z "$WTDIRS" ]; then emit "n/a" "no worktrees directory found"
else
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    if [ ! -d "$d" ]; then emit "n/a" "$d: not a directory"; continue; fi
    wc_=0; stray=0; stale=0; total=0; unk=0
    re=' [0-9]+(\.[A-Za-z0-9]+)?$'
    while IFS= read -r name; do
      [ -z "$name" ] && continue; [ "$name" = ".DS_Store" ] && continue
      total=$((total+1)); full="$d/$name"
      if [ -d "$full" ] && [ -e "$full/.git" ]; then
        wc_=$((wc_+1))
        ap=$(abspath "$full")
        idx=$(awk -F'\t' -v p="$ap" '$1==p{print $2; exit}' "$TMPD/pathidx" 2>/dev/null)
        ct=""; [ -n "$idx" ] && ct=$(kv "$TMPD/g.$idx" ct)
        if [ -n "$ct" ]; then
          ad=$(( (NOW - ct) / 86400 ))
          if [ "$ad" -gt 14 ]; then stale=$((stale+1)); emit WARN "stale worktree $name: last commit ${ad} days ago" "WARN > 14 days"; fi
        else unk=$((unk+1)); fi
        if [[ "$name" =~ $re ]]; then stray=$((stray+1)); emit WARN "stray file in worktrees dir: $name (looks like a Finder duplicate)" "WARN"; fi
      else
        stray=$((stray+1)); if [ -d "$full" ]; then kind_="directory that is not a git worktree"; else kind_="file"; fi
        emit WARN "stray file in worktrees dir: $name ($kind_)" "WARN not a git worktree"
      fi
    done < <(ls -A "$d" 2>/dev/null)
    tag=OK; [ "$wc_" -gt 8 ] && tag=WARN
    emit "$tag" "$(basename "$d"): $wc_ worktrees ($total entries, $stale stale, $unk age unknown, $stray stray)" "WARN > 8 worktrees"
  done <<< "$WTDIRS"
fi

# ---------- Bundles ----------
sec "Bundles"
if [ -z "$BUNDLES_DIR" ]; then
  if [ "$UNPUSHED" -gt 0 ]; then emit WARN "no bundles directory while $UNPUSHED commits are unpushed" "WARN"; else emit "n/a" "no bundles directory (default ~/nle-bundles not found)"; fi
elif [ ! -d "$BUNDLES_DIR" ]; then emit "n/a" "$BUNDLES_DIR: not a directory"
else
  newest=0; old=""; nold=0; nb=0
  for b in "$BUNDLES_DIR"/*.bundle; do
    [ -f "$b" ] || continue
    nb=$((nb+1)); m=$(mtime "$b"); m=${m:-0}
    [ "$m" -gt "$newest" ] && newest=$m
    if [ $((NOW - m)) -gt 2592000 ]; then nold=$((nold+1)); [ "$nold" -le 5 ] && old="$old $(basename "$b")"; fi
  done
  if [ "$nb" -eq 0 ]; then
    if [ "$UNPUSHED" -gt 0 ]; then emit WARN "no bundles in $BUNDLES_DIR while $UNPUSHED commits are unpushed" "WARN"; else emit "n/a" "no bundles in $BUNDLES_DIR"; fi
  else
    h=$(( (NOW - newest) / 3600 )); tag=OK
    [ "$h" -ge 24 ] && [ "$UNPUSHED" -gt 0 ] && tag=WARN
    emit "$tag" "$nb bundles, newest ${h} h old; $UNPUSHED unpushed commits" "WARN newest >= 24 h while anything unpushed"
    [ "$nold" -gt 0 ] && emit OK "$nold bundles older than 30 days (cleanup candidates for the human):$old" "info only"
  fi
fi

# ---------- Verdict ----------
# Headline priority: dataless / hung git / stale lock, then Disk, then Memory, then the rest; report order within a tier.
NSECRED=$(awk -F'\t' '$3=="RED"{s[$2]=1} END{n=0; for(k in s) n++; print n}' "$REC")
if [ "$NRED" -gt 0 ]; then
  V=RED; S=$(awk -F'\t' '$3=="RED" && (best=="" || $1+0<bp){best=$2": "$4; bp=$1+0} END{print best}' "$REC")
elif [ "$NWARN" -gt 0 ]; then
  V=AMBER; S=$(awk -F'\t' '$3=="WARN"{print $2": "$4; exit}' "$REC")
else V=GREEN; S="all probes within thresholds"; fi
SECW=sections; [ "$NSECRED" = 1 ] && SECW=section
SUMMARY="$S ($NRED red in $NSECRED $SECW, $NWARN warn)"

jesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e $'s/\t/\\\\t/g' | tr -d '\000-\010\013-\037'; }

if [ "$JSON" = 1 ]; then
  printf '{"version":"%s","host":"%s","date":"%s","quick":%s,"elapsed_s":%s,"verdict":"%s","summary":"%s","red":%s,"red_sections":%s,"warn":%s,"findings":[' \
    "$VERSION" "$(jesc "$(hostname -s 2>/dev/null)")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$([ "$QUICK" = 1 ] && echo true || echo false)" "$SECONDS" "$V" "$(jesc "$SUMMARY")" "$NRED" "$NSECRED" "$NWARN"
  first=1
  while IFS=$'\t' read -r _ s t m th; do
    [ $first = 1 ] || printf ','
    first=0
    printf '{"section":"%s","status":"%s","metric":"%s","threshold":"%s"}' "$(jesc "$s")" "$(jesc "$t")" "$(jesc "$m")" "$(jesc "$th")"
  done < "$REC"
  printf ']}\n'
else
  printf 'vitals %s  %s  %s%s\n' "$VERSION" "$(hostname -s 2>/dev/null)" "$(date '+%Y-%m-%d %H:%M')" "$([ "$QUICK" = 1 ] && echo '  (quick)')"
  last=""
  while IFS=$'\t' read -r _ s t m th; do
    if [ "$s" != "$last" ]; then printf '\n== %s ==\n' "$s"; last="$s"; fi
    if [ -n "$th" ]; then printf '[%s] %s  (%s)\n' "$t" "$m" "$th"; else printf '[%s] %s\n' "$t" "$m"; fi
  done < "$REC"
  printf '\nVERDICT: %s — %s  [%s s]\n' "$V" "$SUMMARY" "$SECONDS"
fi
exit 0
