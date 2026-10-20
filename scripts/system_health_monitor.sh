#!/usr/bin/env bash
#
# System health monitor.
#
# Checks CPU, memory, disk and process count against thresholds, prints one line
# per metric and appends a single structured line to a log file. Exits non-zero
# if anything crossed its threshold, so cron or CI can act on the result.
#
# Everything comes from /proc and df. No packages beyond coreutils and procps,
# because this is the script that has to run on the box that is already broken.
#
# Usage:
#   ./system_health_monitor.sh
#   CPU_THRESHOLD=70 LOG_FILE=/tmp/health.log ./system_health_monitor.sh
#   REQUIRED_PROCS="sshd containerd" ./system_health_monitor.sh
#   ./system_health_monitor.sh --json
#
set -uo pipefail

CPU_THRESHOLD="${CPU_THRESHOLD:-80}"
MEM_THRESHOLD="${MEM_THRESHOLD:-85}"
DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
PROC_THRESHOLD="${PROC_THRESHOLD:-500}"
DISK_PATHS="${DISK_PATHS:-/}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-1}"
LOG_FILE="${LOG_FILE:-}"
REQUIRED_PROCS="${REQUIRED_PROCS:-}"

JSON=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    -h|--help)
      echo "system_health_monitor.sh [--json]"
      echo "  thresholds: CPU_THRESHOLD MEM_THRESHOLD DISK_THRESHOLD PROC_THRESHOLD"
      echo "  optionals:  DISK_PATHS LOG_FILE REQUIRED_PROCS SAMPLE_SECONDS"
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

command -v awk >/dev/null 2>&1 || { echo "awk is required" >&2; exit 2; }

# --- metrics ----------------------------------------------------------------

cpu_percent() {
  # The first read of /proc/stat is a counter since boot, which tells you
  # nothing. Take two samples and use the delta.
  local a_busy a_idle b_busy b_idle
  read -r a_busy a_idle <<<"$(awk '/^cpu /{print $2+$3+$4, $5+$6}' /proc/stat)"
  sleep "$SAMPLE_SECONDS"
  read -r b_busy b_idle <<<"$(awk '/^cpu /{print $2+$3+$4, $5+$6}' /proc/stat)"

  awk -v ab="$a_busy" -v ai="$a_idle" -v bb="$b_busy" -v bi="$b_idle" 'BEGIN {
    busy = bb - ab
    idle = bi - ai
    total = busy + idle
    if (total <= 0) { print "0.0"; exit }
    printf "%.1f", busy * 100 / total
  }'
}

mem_percent() {
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{
    if (t <= 0) { print "0.0"; exit }
    printf "%.1f", (t - a) * 100 / t
  }' /proc/meminfo
}

disk_percent() {
  df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'
}

proc_count() {
  ps -e --no-headers 2>/dev/null | wc -l | tr -d ' '
}

# --- checks -----------------------------------------------------------------

NAMES=()
VALUES=()
LIMITS=()
STATUS=()
failures=0

check() {
  local name=$1 value=$2 limit=$3 state="ok"
  if awk -v v="$value" -v l="$limit" 'BEGIN{exit !(v+0 > l+0)}'; then
    state="BREACH"
    failures=$((failures + 1))
  fi
  NAMES+=("$name"); VALUES+=("$value"); LIMITS+=("$limit"); STATUS+=("$state")
}

check "cpu" "$(cpu_percent)" "$CPU_THRESHOLD"
check "memory" "$(mem_percent)" "$MEM_THRESHOLD"

for path in $DISK_PATHS; do
  usage=$(disk_percent "$path")
  if [ -n "$usage" ]; then
    check "disk:$path" "$usage" "$DISK_THRESHOLD"
  else
    NAMES+=("disk:$path"); VALUES+=("0"); LIMITS+=("$DISK_THRESHOLD")
    STATUS+=("UNREADABLE")
    failures=$((failures + 1))
  fi
done

check "processes" "$(proc_count)" "$PROC_THRESHOLD"

# A process that must be running is a pass/fail check, not a number, so it does
# not go through check().
for proc in $REQUIRED_PROCS; do
  if pgrep -x "$proc" >/dev/null 2>&1; then
    NAMES+=("proc:$proc"); VALUES+=("1"); LIMITS+=("running"); STATUS+=("ok")
  else
    NAMES+=("proc:$proc"); VALUES+=("0"); LIMITS+=("running"); STATUS+=("MISSING")
    failures=$((failures + 1))
  fi
done

# --- output -----------------------------------------------------------------

timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
host=$(hostname)
overall="ok"
[ "$failures" -gt 0 ] && overall="breach"

if [ "$JSON" -eq 1 ]; then
  printf '{"timestamp":"%s","host":"%s","result":"%s","checks":[' \
    "$timestamp" "$host" "$overall"
  sep=""
  for i in "${!NAMES[@]}"; do
    printf '%s{"name":"%s","value":%s,"limit":"%s","state":"%s"}' \
      "$sep" "${NAMES[$i]}" "${VALUES[$i]}" "${LIMITS[$i]}" "${STATUS[$i]}"
    sep=","
  done
  printf ']}\n'
else
  printf '%s  %s\n' "$host" "$timestamp"
  for i in "${!NAMES[@]}"; do
    printf '  %-12s %8s   limit %-8s %s\n' \
      "${NAMES[$i]}" "${VALUES[$i]}" "${LIMITS[$i]}" "${STATUS[$i]}"
  done
  printf '  result: %s\n' "$overall"
fi

if [ -n "$LOG_FILE" ]; then
  printf '%s %s %s\n' "$timestamp" "$host" "$overall" >> "$LOG_FILE" 2>/dev/null \
    || echo "could not write to $LOG_FILE" >&2
fi

[ "$failures" -gt 0 ] && exit 1
exit 0
