#!/usr/bin/env bash
# vitals.sh - one-shot, read-only health snapshot of the dev machine and its git repos.
# Never deletes, kills (other than its own timed-out probe children), or modifies anything.
# macOS first; degrades to n/a or Linux equivalents. No `set -e`: a failing probe must not kill the report.
set -u
export LC_ALL=C
export GIT_OPTIONAL_LOCKS=0   # git status must not refresh/write the index
VERSION="0.1.0"
GT="${VITALS_GIT_TIMEOUT:-5}"   # seconds for git status / dataless probes (keeps the whole run near 10 s)

usage() {
  cat <<'USAGE'
Usage: vitals.sh [--repo <path>]... [--worktrees <dir>]... [--bundles <dir>] [--json] [--quick]
  --repo <path>       git repo to check (repeatable). Default: cwd's git toplevel.
  --worktrees <dir>   directory of worktrees to scan (repeatable). Default: *-worktrees siblings of the repo.
  --bundles <dir>     directory of git bundles. Default: ~/nle-bundles if it exists.
  --json              emit JSON instead of text.
  --quick             skip du, iCloud/dataless probes and worktree scans.
Env: VITALS_REPOS, VITALS_WORKTREES, VITALS_BUNDLES (colon-separated) apply when the flag is absent.
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
NRED=0; NWARN=0; FIRST_RED=""; FIRST_WARN=""; CUR_SEC=""

have() { command -v "$1" >/dev/null 2>&1; }

# to SECS CMD...: run with a wall-clock limit. gtimeout/timeout if present, else background+kill.
# Callers redirect output to a file (not $(...)): a killed pipeline's orphans must not hold a pipe open.
to() {
  local secs=$1; shift
  if have gtimeout; then gtimeout "$secs" "$@"; return $?; fi
  if have timeout; then timeout "$secs" "$@"; return $?; fi
  "$@" &
  local pid=$! t=0 lim=$((secs*10))
  # Poll instead of wait: a process stuck in uninterruptible I/O (evicted iCloud file) ignores signals,
  # so we signal it and move on rather than block on it.
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$t" -ge "$lim" ]; then pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null; return 124; fi
    sleep 0.1; t=$((t+1))
  done
  wait "$pid" 2>/dev/null
}

sec() { CUR_SEC="$1"; }
emit() { # tag metric [threshold]
  local tag=$1 metric=$2 thr=${3:-}
  metric=$(printf '%s' "$metric" | tr '\t\n' '  ')
  case "$tag" in
    RED)  NRED=$((NRED+1));   [ -z "$FIRST_RED" ]  && FIRST_RED="$CUR_SEC: $metric" ;;
    WARN) NWARN=$((NWARN+1)); [ -z "$FIRST_WARN" ] && FIRST_WARN="$CUR_SEC: $metric" ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$CUR_SEC" "$tag" "$metric" "$thr" >> "$REC"
}

abspath() { ( cd "$1" 2>/dev/null && pwd -P ); }
mtime() { if [ "$MAC" = 1 ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi; }
kv() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }
fnum() { awk -v n="$1" 'BEGIN{printf "%.1f", n}'; }
AWK_DL='$5 ~ /dataless/ {c++} END{print c+0}'
AWK_ETIME='function sec(e,  d,a,n,s,x,i){d=0; if(index(e,"-")){split(e,x,"-"); d=x[1]; e=x[2]} n=split(e,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; return d*86400+s}'

icloud_path() { case "$1" in */Library/Mobile\ Documents/*|"$HOME"/Documents|"$HOME"/Documents/*) return 0 ;; esac; return 1; }

# ---------- resolve targets ----------
TG="$TMPD/targets"; : > "$TG"          # kind|path   (R = explicit repo, W = linked worktree)
BAD_REPOS=""
add_target() { grep -Fxq "$1|$2" "$TG" 2>/dev/null || { grep -q "^[RW]|$(printf '%s' "$2" | sed 's/[][\.*^$/]/\\&/g')\$" "$TG" 2>/dev/null; } || echo "$1|$2" >> "$TG"; }

if [ -z "$REPOS_IN" ]; then
  top=$(git rev-parse --show-toplevel 2>/dev/null); [ -n "$top" ] && REPOS_IN="$top"$'\n'
fi
REPO_LIST=""
while IFS= read -r r; do
  [ -z "$r" ] && continue
  top=$(git -C "$r" rev-parse --show-toplevel 2>/dev/null)
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
    git -C "$r" worktree list --porcelain 2>/dev/null | awk '/^worktree /{n++; if(n>1) print substr($0,10)}' | while IFS= read -r w; do
      [ -d "$w" ] && echo "$(abspath "$w")"
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
ICL_NEEDED=0
while IFS='|' read -r kind p; do [ "$kind" = R ] && icloud_path "$p" && ICL_NEEDED=1; done < "$TG"
BRCTL_PID=""
if [ "$QUICK" = 0 ] && [ "$MAC" = 1 ] && [ "$ICL_NEEDED" = 1 ] && have brctl; then
  # brctl status can run for minutes; stream through sed and keep whatever arrives in 5 s.
  ( to 4 sh -c "brctl status 2>&1 | sed 's/\\x1b\\[[0-9;]*m//g' > '$TMPD/brctl.out'" ) >/dev/null 2>&1 &
  BRCTL_PID=$!
fi

DU_PIDS=""
SCRATCH="/private/tmp/claude-$(id -u)"; [ -d "$SCRATCH" ] || SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
if [ "$QUICK" = 0 ]; then
  n=0
  for p in "$HOME/Library/Caches" "$HOME/.Trash" "$SCRATCH"; do
    n=$((n+1))
    [ -d "$p" ] || continue
    ( to 5 du -sh "$p" > "$TMPD/du.$n" 2>/dev/null ) &
    DU_PIDS="$DU_PIDS $!"
  done
fi

gprobe() { # idx kind path first_of_common(1/0) icloud(1/0)
  local i=$1 kind=$2 p=$3 first=$4 icl=$5 f="$TMPD/g.$i" gd lock rc b n
  {
    echo "path=$p"
    echo "branch=$(git -C "$p" symbolic-ref --short -q HEAD 2>/dev/null || echo detached)"
    lock=$(git -C "$p" rev-parse --git-path index.lock 2>/dev/null)
    case "$lock" in /*) ;; *) lock="$p/$lock" ;; esac
    if [ -e "$lock" ]; then echo "lock=$lock"; echo "lockmtime=$(mtime "$lock")"; fi
    to "$GT" git -C "$p" status --porcelain > "$TMPD/s.$i" 2>/dev/null; rc=$?
    if [ "$rc" -ge 124 ]; then echo "status=hung"; else echo "status=ok"; echo "dirty=$(wc -l < "$TMPD/s.$i" | tr -d ' ')"; fi
    gd=$(git -C "$p" rev-parse --git-common-dir 2>/dev/null)
    case "$gd" in /*) ;; *) gd="$p/$gd" ;; esac
    if [ "$first" = 1 ]; then
      git -C "$p" for-each-ref --format='%(refname:short)|%(upstream:short)|%(upstream:track)' refs/heads > "$TMPD/fe.$i" 2> "$TMPD/fe.err.$i"
      echo "broken_refs=$(grep -c 'broken name' "$TMPD/fe.err.$i")"
      remotes=$(git -C "$p" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null | tr '\n' ' ')
      k=0
      while IFS='|' read -r b up tr_; do
        [ -z "$b" ] && continue
        if [ -n "$up" ] && [ "$tr_" != "[gone]" ]; then
          n=$(printf '%s' "$tr_" | sed -n 's/.*ahead \([0-9]*\).*/\1/p'); echo "A|$b|${n:-0}"
        else
          k=$((k+1))
          if [ "$k" -le 40 ]; then echo "N|$b|$(git -C "$p" rev-list --count "$b" --not $remotes 2>/dev/null || echo 0)"
          else echo "N|$b|0"; fi
        fi
      done < "$TMPD/fe.$i" > "$TMPD/b.$i"
    fi
    if [ "$icl" = 1 ]; then
      to "$GT" bash -c 'cd "$1" && git ls-files -z | xargs -0 ls -lO 2>/dev/null | awk "$2"' _ "$p" "$AWK_DL" > "$TMPD/dt.$i" 2>/dev/null; rc=$?
      if [ "$rc" -ge 124 ]; then echo "dl_tracked=timeout"; else echo "dl_tracked=$(tr -d ' \n' < "$TMPD/dt.$i")"; fi
      to "$GT" bash -c 'find "$1/objects" -type f -exec ls -lO {} + 2>/dev/null | awk "$2"' _ "$gd" "$AWK_DL" > "$TMPD/do.$i" 2>/dev/null; rc=$?
      if [ "$rc" -ge 124 ]; then echo "dl_objects=timeout"; else echo "dl_objects=$(tr -d ' \n' < "$TMPD/do.$i")"; fi
    fi
  } > "$f" 2>/dev/null
}
GPIDS=""; SEEN_GD=""; i=0
if [ "$QUICK" = 0 ]; then ICL_OK=1; else ICL_OK=0; fi
[ "$MAC" = 1 ] || ICL_OK=0
while IFS='|' read -r kind p; do
  [ -z "$p" ] && continue
  i=$((i+1))
  gd=$(git -C "$p" rev-parse --git-common-dir 2>/dev/null); case "$gd" in /*) ;; *) gd="$p/$gd" ;; esac
  gd=$(abspath "$gd")
  first=1; case "$SEEN_GD" in *"|$gd|"*) first=0 ;; esac; SEEN_GD="$SEEN_GD|$gd|"
  icl=0; [ "$kind" = R ] && [ "$ICL_OK" = 1 ] && icloud_path "$p" && icl=1
  gprobe "$i" "$kind" "$p" "$first" "$icl" &
  GPIDS="$GPIDS $!"; eval "GPID_$i=$!"
done < "$TG"
NTARGETS=$i

# ---------- Disk ----------
sec "Disk"
DFP="/"; [ "$MAC" = 1 ] && [ -d /System/Volumes/Data ] && DFP="/System/Volumes/Data"
read -r dtotal davail < <(df -Pk "$DFP" 2>/dev/null | awk 'NR==2{print $2, $4}')
if [ -n "${dtotal:-}" ] && [ "${dtotal:-0}" -gt 0 ] 2>/dev/null; then
  freegb=$(awk -v a="$davail" 'BEGIN{printf "%.1f", a/1048576}')
  usedpct=$(awk -v t="$dtotal" -v a="$davail" 'BEGIN{printf "%d", (t-a)*100/t}')
  tag=OK
  awk -v g="$freegb" -v u="$usedpct" 'BEGIN{exit !(g<30 || u>85)}' && tag=WARN
  awk -v g="$freegb" -v u="$usedpct" 'BEGIN{exit !(g<15 || u>92)}' && tag=RED
  emit "$tag" "$DFP: ${freegb} GB free, ${usedpct}% used" "WARN <30 GB or >85% used; RED <15 GB or >92%"
else
  emit "n/a" "df unavailable for $DFP"
fi
if [ "$QUICK" = 0 ]; then
  for pid in $DU_PIDS; do wait "$pid" 2>/dev/null; done
  n=0
  for p in "$HOME/Library/Caches" "$HOME/.Trash" "$SCRATCH"; do
    n=$((n+1))
    label=$(printf '%s' "$p" | sed "s|^$HOME|~|")
    if [ ! -d "$p" ]; then emit "n/a" "$label: not present"; continue; fi
    sz=$(cut -f1 "$TMPD/du.$n" 2>/dev/null | head -1)
    if [ -z "$sz" ]; then emit "n/a" "$label: du timed out (>5 s) or unreadable" "5 s limit"; continue; fi
    tag=OK
    case "$sz" in *T) tag=WARN ;; *G) awk -v s="${sz%G}" 'BEGIN{exit !(s+0>=10)}' && tag=WARN ;; esac
    emit "$tag" "$label: $sz" "WARN >= 10 GB"
  done
else
  emit "n/a" "Caches/Trash/scratchpad sizes skipped (--quick)"
fi

# ---------- Memory ----------
sec "Memory"
if [ "$MAC" = 1 ]; then
  memb=$(sysctl -n hw.memsize 2>/dev/null); memgb=$(awk -v b="${memb:-0}" 'BEGIN{printf "%.0f", b/1073741824}')
  freepct=$(memory_pressure 2>/dev/null | awk -F': ' '/System-wide memory free percentage/{gsub(/%/,"",$2); print $2+0}')
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
    pct=$(awk -v t="$swt" -v u="$swu" 'BEGIN{ if(t>0) printf "%d", u*100/t; else print 0 }')
    tag=OK; [ "$pct" -gt 50 ] && tag=WARN; [ "$pct" -gt 75 ] && tag=RED
    emit "$tag" "swap $(awk -v u="$swu" 'BEGIN{printf "%.1f", u/1024}') GB of $(awk -v t="$swt" 'BEGIN{printf "%.1f", t/1024}') GB used (${pct}%)" "WARN >50% used; RED >75%"
  else emit "n/a" "swap: sysctl vm.swapusage unavailable"; fi
  po=$(vm_stat 2>/dev/null | awk '/^Pageouts:/{gsub(/\./,"",$2); print $2}')
  [ -n "$po" ] && emit "OK" "pageouts since boot: $po pages" "info only" || emit "n/a" "pageouts unavailable"
elif [ -r /proc/meminfo ]; then
  mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo); ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  st=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo); sf=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
  freepct=$(awk -v a="${ma:-0}" -v t="${mt:-1}" 'BEGIN{printf "%d", a*100/t}')
  tag=OK; [ "$freepct" -lt 30 ] && tag=WARN; [ "$freepct" -lt 15 ] && tag=RED
  emit "$tag" "$(awk -v t="$mt" 'BEGIN{printf "%.0f", t/1048576}') GB physical, ${freepct}% available" "WARN <30% free; RED <15%"
  pct=$(awk -v t="${st:-0}" -v f="${sf:-0}" 'BEGIN{ if(t>0) printf "%d", (t-f)*100/t; else print 0 }')
  tag=OK; [ "$pct" -gt 50 ] && tag=WARN; [ "$pct" -gt 75 ] && tag=RED
  emit "$tag" "swap ${pct}% used of $(awk -v t="${st:-0}" 'BEGIN{printf "%.1f", t/1048576}') GB" "WARN >50% used; RED >75%"
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
PSC=$(ps -Ao comm= 2>/dev/null | awk '{sub(/^.*\//,""); print}')
cnt() { printf '%s\n' "$PSC" | awk -v pat="$1" -v mode="$2" '{ if(mode=="eq" ? $0==pat : index($0,pat)==1 ) c++ } END{print c+0}'; }
emit OK "process counts: claude $(cnt claude eq), node $(cnt node eq), python $(cnt python pre), Code Helper $(printf '%s\n' "$PSC" | grep -c 'Code Helper')" "info only"

# ---------- iCloud / dataless ----------
sec "iCloud"
if [ "$QUICK" = 1 ]; then emit "n/a" "skipped (--quick)"
elif [ "$MAC" != 1 ]; then emit "n/a" "iCloud dataless probes are macOS-only"
elif [ "$ICL_NEEDED" = 0 ]; then emit "n/a" "no repo under ~/Documents or ~/Library/Mobile Documents"
elif ! have brctl; then emit "n/a" "brctl not found"
else
  [ -n "$BRCTL_PID" ] && wait "$BRCTL_PID" 2>/dev/null
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
  i=0
  while IFS='|' read -r kind p; do
    [ -z "$p" ] && continue; i=$((i+1))
    [ "$kind" = R ] && icloud_path "$p" || continue
    eval "gp=\${GPID_$i:-}"; [ -n "$gp" ] && wait "$gp" 2>/dev/null
    f="$TMPD/g.$i"; nm=$(basename "$p")
    for what in tracked objects; do
      v=$(kv "$f" "dl_$what")
      case "$v" in
        timeout) emit RED "$nm: dataless $what count timed out (>${GT} s): treat as evicted files" "RED any dataless or timeout" ;;
        ""|0)    emit OK "$nm: 0 dataless $what files" "RED any dataless" ;;
        *)       emit RED "$nm: $v dataless $what files; fix: brctl download \"$p\"" "RED any dataless" ;;
      esac
    done
  done < "$TG"
fi

# ---------- Git health ----------
sec "Git"
for pid in $GPIDS; do wait "$pid" 2>/dev/null; done
while IFS= read -r r; do [ -n "$r" ] && emit WARN "not a git repo: $r" "path given via --repo"; done <<< "$BAD_REPOS"
HG=$(ps -Ao pid=,etime=,comm= 2>/dev/null | awk "$AWK_ETIME"'{ nm=$3; for(i=4;i<=NF;i++) nm=nm" "$i; sub(/^.*\//,"",nm); if(nm=="git" && sec($2)>600) printf "pid %s (%s) ", $1, $2 }')
if [ -n "$HG" ]; then emit WARN "hung git processes (>10 min): $HG" "WARN git older than 10 min"; else emit OK "no git process older than 10 min" "WARN > 10 min"; fi
UNPUSHED=0; i=0
while IFS='|' read -r kind p; do
  [ -z "$p" ] && continue; i=$((i+1)); f="$TMPD/g.$i"; nm=$(basename "$p")
  [ -s "$f" ] || { emit "n/a" "$nm: probe produced no data"; continue; }
  if [ "$(kv "$f" status)" = hung ]; then
    emit RED "$nm: git status hung (>${GT} s); likely dataless/evicted files: $p" "RED > ${GT} s"
  else
    emit OK "$nm [$(kv "$f" branch)] ($kind) dirty files: $(kv "$f" dirty)" "info only"
  fi
  lm=$(kv "$f" lockmtime)
  if [ -n "$lm" ]; then
    age=$((NOW - lm))
    [ "$age" -gt 600 ] && emit RED "$nm: stale index.lock ($((age/60)) min old): $(kv "$f" lock)" "RED lock older than 10 min"
  fi
  br=$(kv "$f" broken_refs)
  [ "${br:-0}" -gt 0 ] 2>/dev/null && emit WARN "$nm: $br git refs with broken names (Finder duplicates like 'name 2' in .git/refs); human removes after bundling" "WARN any broken ref"
  if [ -f "$TMPD/b.$i" ]; then
    nb=0; na=0; nn=0; nolist=""
    while IFS='|' read -r t b n; do
      nb=$((nb+1))
      if [ "$t" = A ]; then
        if [ "${n:-0}" -gt 0 ] 2>/dev/null; then na=$((na+1)); UNPUSHED=$((UNPUSHED+n)); emit WARN "$nm: branch $b has $n unpushed commits" "WARN ahead > 0"; fi
      else
        nn=$((nn+1)); [ "${n:-0}" -gt 0 ] 2>/dev/null && UNPUSHED=$((UNPUSHED+n))
        [ "$nn" -le 6 ] && nolist="$nolist $b(${n} not on any remote)"
      fi
    done < "$TMPD/b.$i"
    [ "$nn" -gt 0 ] && emit WARN "$nm: $nn of $nb local branches have no upstream:$nolist" "WARN no upstream"
    [ "$na" -eq 0 ] && [ "$nn" -eq 0 ] && emit OK "$nm: $nb local branches, all pushed" "WARN ahead > 0 or no upstream"
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
    wc_=0; stray=0; stale=0; total=0
    re=' [0-9]+(\.[A-Za-z0-9]+)?$'
    while IFS= read -r name; do
      [ -z "$name" ] && continue; [ "$name" = ".DS_Store" ] && continue
      total=$((total+1)); full="$d/$name"
      if [ -d "$full" ] && [ -e "$full/.git" ]; then
        wc_=$((wc_+1))
        to 5 git -C "$full" log -1 --format=%ct > "$TMPD/ct" 2>/dev/null; ct=$(tr -d ' \n' < "$TMPD/ct")
        if [ -n "$ct" ]; then
          ad=$(( (NOW - ct) / 86400 ))
          if [ "$ad" -gt 14 ]; then stale=$((stale+1)); emit WARN "stale worktree $name: last commit ${ad} days ago" "WARN > 14 days"; fi
        fi
        if [[ "$name" =~ $re ]]; then stray=$((stray+1)); emit WARN "stray file in worktrees dir: $name (looks like a Finder duplicate)" "WARN"; fi
      else
        stray=$((stray+1)); if [ -d "$full" ]; then kind_="directory that is not a git worktree"; else kind_="file"; fi
        emit WARN "stray file in worktrees dir: $name ($kind_)" "WARN not a git worktree"
      fi
    done < <(ls -A "$d" 2>/dev/null)
    tag=OK; [ "$wc_" -gt 8 ] && tag=WARN
    emit "$tag" "$(basename "$d"): $wc_ worktrees ($total entries, $stale stale, $stray stray)" "WARN > 8 worktrees"
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
if [ "$NRED" -gt 0 ]; then V=RED; S="$FIRST_RED"
elif [ "$NWARN" -gt 0 ]; then V=AMBER; S="$FIRST_WARN"
else V=GREEN; S="all probes within thresholds"; fi
SUMMARY="$S ($NRED red, $NWARN warn)"

jesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e $'s/\t/\\\\t/g' | tr -d '\000-\010\013-\037'; }

if [ "$JSON" = 1 ]; then
  printf '{"version":"%s","host":"%s","date":"%s","quick":%s,"verdict":"%s","summary":"%s","red":%s,"warn":%s,"findings":[' \
    "$VERSION" "$(jesc "$(hostname -s 2>/dev/null)")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$([ "$QUICK" = 1 ] && echo true || echo false)" "$V" "$(jesc "$SUMMARY")" "$NRED" "$NWARN"
  first=1
  while IFS=$'\t' read -r s t m th; do
    [ $first = 1 ] || printf ','
    first=0
    printf '{"section":"%s","status":"%s","metric":"%s","threshold":"%s"}' "$(jesc "$s")" "$(jesc "$t")" "$(jesc "$m")" "$(jesc "$th")"
  done < "$REC"
  printf ']}\n'
else
  printf 'vitals %s  %s  %s%s\n' "$VERSION" "$(hostname -s 2>/dev/null)" "$(date '+%Y-%m-%d %H:%M')" "$([ "$QUICK" = 1 ] && echo '  (quick)')"
  last=""
  while IFS=$'\t' read -r s t m th; do
    if [ "$s" != "$last" ]; then printf '\n== %s ==\n' "$s"; last="$s"; fi
    if [ -n "$th" ]; then printf '[%s] %s  (%s)\n' "$t" "$m" "$th"; else printf '[%s] %s\n' "$t" "$m"; fi
  done < "$REC"
  printf '\nVERDICT: %s — %s\n' "$V" "$SUMMARY"
fi
exit 0
