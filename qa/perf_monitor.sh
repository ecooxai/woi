#!/usr/bin/env bash
# Samples CPU% and RSS of every Woi process once per second and writes a CSV
# plus a min/avg/max summary.
#
#   qa/perf_monitor.sh [-d SECONDS] [-o OUT.csv] [-l LABEL] [-c COMM_REGEX] [-p PID]...
#
#   -d  duration in seconds (default 60; 0 = until Ctrl+C)
#   -o  CSV path (default /tmp/woi-perf-<label>.csv); the summary goes next to
#       it as <OUT>.summary.txt and is also printed
#   -l  scenario label stored in every row (default "run")
#   -c  regex on the process name (comm) selecting the root processes
#       (default '^woi'); every descendant is included as well (pw-record,
#       pw-play, viewer sub-processes...)
#   -p  explicit root PID (repeatable; overrides -c)
#
# CPU% is per core (100 = one full core), computed from utime+stime deltas in
# /proc/<pid>/stat over the real sampling interval, threads included. RSS is
# VmRSS in MB. Each sample has one row per process and one TOTAL row; the
# set of processes is re-discovered every second so sub-windows and audio
# helpers that start later are picked up.
#
# CSV columns: label,t_s,pid,comm,cpu_pct,rss_mb
set -u

DURATION=60
OUT=""
LABEL=run
COMM_RE='^woi'
ROOTS=()
while getopts "d:o:l:c:p:h" opt; do
  case $opt in
    d) DURATION=$OPTARG ;;
    o) OUT=$OPTARG ;;
    l) LABEL=$OPTARG ;;
    c) COMM_RE=$OPTARG ;;
    p) ROOTS+=("$OPTARG") ;;
    *) sed -n '2,23p' "$0"; exit 2 ;;
  esac
done
[ -n "$OUT" ] || OUT=/tmp/woi-perf-$LABEL.csv
mkdir -p "$(dirname "$OUT")"
SUMMARY=${OUT%.csv}.summary.txt
HZ=$(getconf CLK_TCK)

PAGE_KB=$(( $(getconf PAGESIZE) / 1024 ))

# Roots (by -p or comm regex) plus all their descendants, from one ps call.
pids() {
  ps -e -o pid=,ppid=,comm= | awk -v re="$COMM_RE" -v roots="${ROOTS[*]:-}" '
    { pid[NR] = $1; parent[$1] = $2; if (roots == "" && $3 ~ re) keep[$1] = 1 }
    END {
      n = split(roots, rs, " "); for (i = 1; i <= n; i++) keep[rs[i]] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= NR; i++) { p = pid[i]; if (!(p in keep) && (parent[p] in keep)) { keep[p] = 1; changed = 1 } }
      }
      for (p in keep) print p
    }'
}

# Sets TICKS, RSS_KB and COMM for a pid without forking.
stat_of() {
  local s rest f
  { read -r s </proc/$1/stat && read -r _ rss _ </proc/$1/statm; } 2>/dev/null || return 1
  COMM=${s#*(}; COMM=${COMM%)*}; COMM=${COMM// /_}
  rest=${s##*) }
  read -r -a f <<<"$rest"
  # f[0] = state (field 3), so utime (14) and stime (15) are f[11] and f[12].
  TICKS=$(( f[11] + f[12] ))
  RSS_KB=$(( rss * PAGE_KB ))
}

now_ms() { local t; t=$(date +%s%N); echo $(( t / 1000000 )); }

echo "label,t_s,pid,comm,cpu_pct,rss_mb" >"$OUT"
declare -A PREV
start=$(now_ms)
prev_t=$start
for p in $(pids); do stat_of "$p" && PREV[$p]=$TICKS; done
stop=0
trap 'stop=1' INT TERM
n=0
next=$start
while [ $stop = 0 ]; do
  next=$(( next + 1000 ))
  wait_ms=$(( next - $(now_ms) ))
  [ $wait_ms -gt 0 ] && sleep "$(printf '%d.%03d' $((wait_ms / 1000)) $((wait_ms % 1000)))"
  now=$(now_ms)
  dt=$(( now - prev_t )); [ $dt -gt 0 ] || dt=1
  prev_t=$now
  t=$(( now - start ))
  tsec=$(printf '%d.%d' $((t / 1000)) $((t % 1000 / 100)))
  tot_cpu=0; tot_rss=0; seen=0; rows=""
  declare -A CUR=()
  for p in $(pids); do
    stat_of "$p" || continue
    CUR[$p]=$TICKS
    [ -n "${PREV[$p]:-}" ] || continue # first sight: no delta yet
    # cpu in hundredths of a percent: ticks / HZ / (dt / 1000) * 100 * 100
    c=$(( (TICKS - PREV[$p]) * 10000000 / (HZ * dt) ))
    tot_cpu=$(( tot_cpu + c )); tot_rss=$(( tot_rss + RSS_KB ))
    rows+=$(printf '%s,%s,%s,%s,%d.%02d,%d.%d' "$LABEL" "$tsec" "$p" "$COMM" $((c / 100)) $((c % 100)) $((RSS_KB / 1024)) $((RSS_KB % 1024 * 10 / 1024)))$'\n'
    seen=1
  done
  PREV=()
  for p in "${!CUR[@]}"; do PREV[$p]=${CUR[$p]}; done
  unset CUR
  if [ $seen = 1 ]; then
    printf '%s' "$rows" >>"$OUT"
    printf '%s,%s,0,TOTAL,%d.%02d,%d.%d\n' "$LABEL" "$tsec" $((tot_cpu / 100)) $((tot_cpu % 100)) \
      $((tot_rss / 1024)) $((tot_rss % 1024 * 10 / 1024)) >>"$OUT"
  fi
  n=$((n + 1))
  [ "$DURATION" != 0 ] && [ $n -ge "$DURATION" ] && break
done

# Summary: per process name (pids of the same name pooled) and TOTAL.
awk -F, -v label="$LABEL" -v out="$OUT" '
  NR == 1 { next }
  {
    k = $4; c = $5 + 0; r = $6 + 0
    if (!(k in cnt)) { cmin[k] = c; cmax[k] = c; rmin[k] = r; rmax[k] = r; rfirst[k] = r; keys[++nk] = k }
    cnt[k]++; csum[k] += c; rsum[k] += r; rlast[k] = r
    if (c < cmin[k]) cmin[k] = c; if (c > cmax[k]) cmax[k] = c
    if (r < rmin[k]) rmin[k] = r; if (r > rmax[k]) rmax[k] = r
  }
  END {
    printf "scenario: %s  (%s)\n", label, out
    printf "%-16s %7s %8s %8s %8s %9s %9s %9s %10s\n", "process", "samples", "cpu_min", "cpu_avg", "cpu_max", "rss_min", "rss_avg", "rss_max", "rss_growth"
    for (i = 1; i <= nk; i++) {
      k = keys[i]
      printf "%-16s %7d %7.2f%% %7.2f%% %7.2f%% %7.1fMB %7.1fMB %7.1fMB %+8.1fMB\n", k, cnt[k], cmin[k], csum[k] / cnt[k], cmax[k], rmin[k], rsum[k] / cnt[k], rmax[k], rlast[k] - rfirst[k]
    }
  }' "$OUT" | tee "$SUMMARY"
