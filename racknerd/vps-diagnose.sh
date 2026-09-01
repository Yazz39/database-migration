#!/usr/bin/env bash
# Diagnose a sluggish/unresponsive VPS and optionally reclaim memory.
#
# The SolusVM API cannot do this -- it controls the hypervisor, not the
# guest OS. Run this ON the VPS over SSH.
#
#   scp racknerd/vps-diagnose.sh you@vps:/tmp/
#   ssh you@vps 'sudo bash /tmp/vps-diagnose.sh'
#   ssh you@vps 'sudo bash /tmp/vps-diagnose.sh --drop-caches'
#
# Default is read-only. --drop-caches only acts if it is actually warranted.

set -uo pipefail

DROP_CACHES=0
FORCE=0
AGENT_UNIT="${AGENT_UNIT:-hermes}"

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \?//'
    cat <<'EOF'

Options:
  --drop-caches   reclaim page cache if available memory is genuinely low
  --force         drop caches even when memory looks healthy
  --agent NAME    service name of your agent (default: hermes)
  -h, --help      this message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --drop-caches) DROP_CACHES=1 ;;
        --force)       FORCE=1; DROP_CACHES=1 ;;
        --agent)       AGENT_UNIT="${2:?--agent needs a name}"; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

hr()      { printf '\n\033[1m== %s\033[0m\n' "$1"; }
warn()    { printf '  \033[33m! %s\033[0m\n' "$1"; }
bad()     { printf '  \033[31mX %s\033[0m\n' "$1"; }
good()    { printf '  \033[32mok\033[0m %s\n' "$1"; }
have()    { command -v "$1" >/dev/null 2>&1; }

meminfo() { awk -v k="$1" '$1==k":"{print $2}' /proc/meminfo; }  # kB

hr "Host"
echo "  $(hostname) -- $(uname -sr)"
[ -r /etc/os-release ] && . /etc/os-release && echo "  ${PRETTY_NAME:-unknown}"
echo "  uptime:$(uptime | sed 's/.*up/ up/')"

hr "Load"
read -r l1 l5 l15 _ < /proc/loadavg
cores=$(nproc 2>/dev/null || echo 1)
echo "  1m=$l1  5m=$l5  15m=$l15  across ${cores} core(s)"
if awk -v l="$l1" -v c="$cores" 'BEGIN{exit !(l > c*2)}'; then
    bad "load is more than 2x core count -- the box is saturated, not short on cache"
elif awk -v l="$l1" -v c="$cores" 'BEGIN{exit !(l > c)}'; then
    warn "load exceeds core count"
else
    good "load is normal"
fi

hr "Memory"
total=$(meminfo MemTotal); avail=$(meminfo MemAvailable); free_kb=$(meminfo MemFree)
cached=$(meminfo Cached); buffers=$(meminfo Buffers)
swaptotal=$(meminfo SwapTotal); swapfree=$(meminfo SwapFree)
pct_avail=$(( avail * 100 / total ))
printf '  total %sM | available %sM (%s%%) | free %sM | cache+buffers %sM\n' \
    $((total/1024)) $((avail/1024)) "$pct_avail" $((free_kb/1024)) $(((cached+buffers)/1024))

if [ "$swaptotal" -gt 0 ]; then
    swapused=$(( (swaptotal - swapfree) / 1024 ))
    swappct=$(( (swaptotal - swapfree) * 100 / swaptotal ))
    printf '  swap  %sM used of %sM (%s%%)\n' "$swapused" $((swaptotal/1024)) "$swappct"
    [ "$swappct" -gt 50 ] && bad "heavy swap use -- this is the usual cause of a 'hung' VPS"
else
    echo "  swap  none configured"
fi

MEM_TIGHT=0
if [ "$pct_avail" -lt 10 ]; then
    MEM_TIGHT=1
    bad "under 10% memory available -- genuine pressure"
elif [ "$pct_avail" -lt 20 ]; then
    MEM_TIGHT=1
    warn "under 20% memory available"
else
    good "${pct_avail}% available -- memory is fine"
    echo "     (cache counts as available; a large 'cached' number is healthy,"
    echo "      not a leak, and dropping it will not speed anything up)"
fi

hr "Top memory consumers"
ps -eo pid,ppid,rss,pcpu,comm --sort=-rss 2>/dev/null | head -8 | \
    awk 'NR==1{printf "  %-8s %-8s %-10s %-6s %s\n",$1,$2,"RSS(MB)",$4,$5; next}
         {printf "  %-8s %-8s %-10.1f %-6s %s\n",$1,$2,$3/1024,$4,$5}'

hr "OOM kills"
oom=""
if have journalctl; then
    oom=$(journalctl -k --since "24 hours ago" 2>/dev/null | grep -ci "out of memory\|oom-kill" || true)
elif [ -r /var/log/kern.log ]; then
    oom=$(grep -ci "out of memory\|oom-kill" /var/log/kern.log 2>/dev/null || true)
fi
if [ -n "$oom" ] && [ "$oom" -gt 0 ] 2>/dev/null; then
    bad "$oom OOM-kill events in the last 24h -- the kernel is killing processes"
    echo "     your agent was probably one of them; cache clearing will not fix this"
else
    good "no OOM kills found"
fi

hr "Disk"
df -h / 2>/dev/null | awk 'NR==2{printf "  / %s used of %s (%s)\n",$3,$2,$5}'
root_pct=$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
[ -n "${root_pct:-}" ] && [ "$root_pct" -gt 90 ] && bad "root filesystem over 90% -- a full disk hangs services hard"
df -i / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); if ($5+0 > 90) print "  X inodes over 90% used"}'

hr "Agent: $AGENT_UNIT"
if have systemctl && systemctl list-unit-files 2>/dev/null | grep -q "^${AGENT_UNIT}"; then
    state=$(systemctl is-active "$AGENT_UNIT" 2>/dev/null)
    echo "  state: $state"
    [ "$state" != "active" ] && bad "not running -- 'journalctl -u $AGENT_UNIT -n 50' for why"
    systemctl show "$AGENT_UNIT" -p NRestarts 2>/dev/null | grep -q 'NRestarts=0' || \
        warn "$(systemctl show "$AGENT_UNIT" -p NRestarts 2>/dev/null) -- it keeps restarting"
elif matches=$(pgrep -af -- "$AGENT_UNIT" 2>/dev/null \
                 | grep -v "vps-diagnose" | grep -v "^$$ "); [ -n "$matches" ]; then
    echo "  running (not a systemd unit):"
    echo "$matches" | head -3 | cut -c1-110 | sed 's/^/    /'
else
    warn "no '$AGENT_UNIT' service or process found -- pass --agent NAME if it is called something else"
fi

hr "Cache"
if [ "$DROP_CACHES" -eq 0 ]; then
    echo "  read-only run; re-run with --drop-caches to reclaim page cache"
elif [ "$(id -u)" -ne 0 ]; then
    bad "dropping caches needs root -- re-run with sudo"
elif [ "$MEM_TIGHT" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
    warn "skipped: ${pct_avail}% memory is available, so there is nothing to reclaim"
    echo "     the kernel already evicts cache automatically under pressure."
    echo "     use --force only if you want it done regardless."
else
    before=$(meminfo MemAvailable)
    sync
    echo 3 > /proc/sys/vm/drop_caches && echo "  dropped page cache, dentries and inodes"
    after=$(meminfo MemAvailable)
    printf '  available: %sM -> %sM (%+dM)\n' \
        $((before/1024)) $((after/1024)) $(( (after - before) / 1024 ))
    good "done -- note this is cosmetic; re-read files will simply repopulate cache"
fi

hr "Summary"
if [ "$MEM_TIGHT" -eq 1 ]; then
    echo "  Real memory pressure. Look at the top consumers above, add swap,"
    echo "  or size up the plan. Dropping cache buys seconds, not a fix."
elif [ -n "$oom" ] && [ "$oom" -gt 0 ] 2>/dev/null; then
    echo "  Memory looks fine now but the kernel has been OOM-killing."
    echo "  Cap your agent's memory or add swap."
else
    echo "  No memory problem visible. If the agent is still unresponsive,"
    echo "  the cause is elsewhere: check its logs, the load figure above,"
    echo "  and disk space."
fi
