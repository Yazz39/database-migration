#!/usr/bin/env bash
# Repair an agent (default: hermes) that keeps dying on a small VPS, and
# verify it actually stays up.
#
# Run ON the VPS as root -- over SSH, or by pasting into the SolusVM serial
# console if SSH is down:
#
#   sudo bash fix-hermes.sh                 # diagnose + repair + verify
#   sudo bash fix-hermes.sh --dry-run       # show the plan, change nothing
#   sudo bash fix-hermes.sh --agent myagent
#
# Most common cause on a budget VPS: not enough RAM, no swap, so the kernel
# OOM-kills the agent. This adds swap, makes the service restart itself, and
# confirms it survives.

set -uo pipefail

AGENT="${AGENT:-hermes}"
SWAP_SIZE=""
DO_SWAP=1
DRY_RUN=0
CREATE_UNIT=""
SETTLE=20

while [ $# -gt 0 ]; do
    case "$1" in
        --agent)       AGENT="${2:?--agent needs a name}"; shift ;;
        --swap)        SWAP_SIZE="${2:?--swap needs a size, e.g. 2G}"; shift ;;
        --no-swap)     DO_SWAP=0 ;;
        --create-unit) CREATE_UNIT="${2:?--create-unit needs a command}"; shift ;;
        --dry-run)     DRY_RUN=1 ;;
        -h|--help)     sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

hr()   { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mok\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mX\033[0m  %s\n' "$1"; }
act()  { printf '  \033[36m->\033[0m %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then act "would run: $*"; else "$@"; fi; }
meminfo() { awk -v k="$1" '$1==k":"{print $2}' /proc/meminfo; }

SCRIPT_NAME=$(basename "$0")
# pgrep -f matches our own argv (the script path and --agent NAME both contain
# the agent name), so filter ourselves out by reading each cmdline.
find_agent_pids() {
    local pid cmd out=""
    for pid in $(pgrep -f -- "$AGENT" 2>/dev/null); do
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "$PPID" ] && continue
        [ -r "/proc/$pid/cmdline" ] || continue   # it may have exited already
        cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") || continue
        [ -z "$cmd" ] && continue
        case "$cmd" in *"$SCRIPT_NAME"*) continue ;; esac
        out="$out $pid"
    done
    echo "${out# }"
}

FIXES=()
PROBLEMS=()

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    bad "must run as root: sudo bash $0"
    exit 2
fi

# ---------------------------------------------------------------- diagnose
hr "What is wrong"

HAS_SYSTEMD=0
UNIT=""
if have systemctl && systemctl list-units >/dev/null 2>&1; then
    HAS_SYSTEMD=1
    for candidate in "$AGENT" "$AGENT.service" "${AGENT}d" "${AGENT}-agent"; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${candidate%.service}\.service"; then
            UNIT="${candidate%.service}.service"
            break
        fi
    done
fi

if [ -n "$UNIT" ]; then
    STATE=$(systemctl is-active "$UNIT" 2>/dev/null)
    NRESTARTS=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null || echo 0)
    echo "  unit:     $UNIT"
    echo "  state:    $STATE"
    echo "  restarts: ${NRESTARTS:-0}"
    [ "$STATE" != "active" ] && PROBLEMS+=("$UNIT is $STATE")
    [ "${NRESTARTS:-0}" -gt 3 ] 2>/dev/null && PROBLEMS+=("$UNIT has restarted ${NRESTARTS} times -- crash loop")
elif pids=$(find_agent_pids); [ -n "$pids" ]; then
    echo "  running as a bare process (no systemd unit):"
    # shellcheck disable=SC2086
    ps -o pid,rss,etime,cmd -p $pids 2>/dev/null | tail -n +2 | cut -c1-100 | sed 's/^/    /'
    PROBLEMS+=("no systemd unit -- nothing restarts $AGENT when it dies")
else
    bad "$AGENT is not running and has no systemd unit"
    PROBLEMS+=("$AGENT is not running")
fi

# Why did it die?
OOM_COUNT=0
if have journalctl; then
    OOM_COUNT=$(journalctl -k --since "48 hours ago" --no-pager 2>/dev/null \
                | grep -ci "out of memory\|oom-kill\|oom_reaper" || true)
elif [ -r /var/log/kern.log ]; then
    OOM_COUNT=$(grep -ci "out of memory\|oom-kill" /var/log/kern.log 2>/dev/null || true)
fi
OOM_COUNT=${OOM_COUNT:-0}
if [ "$OOM_COUNT" -gt 0 ] 2>/dev/null; then
    bad "$OOM_COUNT OOM-kill events in 48h -- the kernel is killing processes for memory"
    PROBLEMS+=("kernel OOM-killing processes")
    if have journalctl; then
        journalctl -k --since "48 hours ago" --no-pager 2>/dev/null \
            | grep -i "killed process" | tail -3 | cut -c1-120 | sed 's/^/    /'
    fi
else
    ok "no OOM kills in the last 48h"
fi

if [ -n "$UNIT" ] && have journalctl; then
    echo "  last log lines:"
    journalctl -u "$UNIT" -n 6 --no-pager 2>/dev/null | tail -6 | cut -c1-120 | sed 's/^/    /' \
        || echo "    (none)"
fi

# ---------------------------------------------------------------- memory
hr "Memory"
TOTAL_KB=$(meminfo MemTotal); AVAIL_KB=$(meminfo MemAvailable)
SWAP_KB=$(meminfo SwapTotal)
TOTAL_MB=$((TOTAL_KB/1024)); SWAP_MB=$((SWAP_KB/1024))
printf '  RAM %sM total, %sM available | swap %sM\n' \
    "$TOTAL_MB" "$((AVAIL_KB/1024))" "$SWAP_MB"

if [ "$SWAP_KB" -eq 0 ]; then
    bad "no swap configured"
    PROBLEMS+=("no swap -- an agent spike gets OOM-killed instead of paging out")
else
    ok "swap present"
fi

if [ -z "$SWAP_SIZE" ]; then
    if   [ "$TOTAL_MB" -le 1200 ]; then SWAP_SIZE="2G"
    elif [ "$TOTAL_MB" -le 2500 ]; then SWAP_SIZE="2G"
    elif [ "$TOTAL_MB" -le 5000 ]; then SWAP_SIZE="4G"
    else SWAP_SIZE="4G"; fi
fi

# ---------------------------------------------------------------- disk
hr "Disk"
DISK_PCT=$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
DISK_AVAIL_MB=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
echo "  / is ${DISK_PCT}% full, ${DISK_AVAIL_MB}M free"
if [ "${DISK_PCT:-0}" -gt 90 ]; then
    bad "disk over 90% -- services fail in confusing ways when they cannot write"
    PROBLEMS+=("disk ${DISK_PCT}% full")
    echo "  biggest directories:"
    du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -5 | sed 's/^/    /'
    warn "not deleting anything automatically -- review the list above"
else
    ok "disk has room"
fi

# ---------------------------------------------------------------- repair
hr "Repairs"

# 1. swap
if [ "$DO_SWAP" -eq 1 ] && [ "$SWAP_KB" -eq 0 ]; then
    NEED_MB=$(( ${SWAP_SIZE%G} * 1024 ))
    if [ "${DISK_AVAIL_MB:-0}" -lt $(( NEED_MB + 1024 )) ]; then
        warn "not enough free disk for a ${SWAP_SIZE} swapfile -- skipping"
    elif [ -e /swapfile ]; then
        warn "/swapfile already exists but is not active -- trying to enable it"
        run swapon /swapfile 2>/dev/null && { ok "swap enabled"; FIXES+=("enabled existing /swapfile"); } \
            || warn "could not enable /swapfile"
    else
        act "creating a ${SWAP_SIZE} swapfile"
        if [ "$DRY_RUN" -eq 0 ]; then
            if fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || \
               dd if=/dev/zero of=/swapfile bs=1M count="$NEED_MB" status=none 2>/dev/null; then
                chmod 600 /swapfile
                if mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
                    grep -q '^/swapfile' /etc/fstab 2>/dev/null || \
                        echo '/swapfile none swap sw 0 0' >> /etc/fstab
                    ok "swap active and persisted in /etc/fstab"
                    FIXES+=("added ${SWAP_SIZE} swap")
                else
                    rm -f /swapfile
                    warn "swapon failed -- container virtualisation often forbids swap"
                fi
            else
                warn "could not allocate the swapfile"
            fi
        else
            FIXES+=("would add ${SWAP_SIZE} swap")
        fi
    fi
    # Prefer keeping the agent resident over aggressive swapping.
    if [ "$DRY_RUN" -eq 0 ] && [ -w /proc/sys/vm/swappiness ]; then
        echo 10 > /proc/sys/vm/swappiness 2>/dev/null
        grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null || \
            echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi
fi

# 2. make it restart itself
if [ -n "$UNIT" ]; then
    RESTART_POLICY=$(systemctl show "$UNIT" -p Restart --value 2>/dev/null)
    if [ "$RESTART_POLICY" = "always" ] || [ "$RESTART_POLICY" = "on-failure" ]; then
        ok "restart policy is already '$RESTART_POLICY'"
    else
        act "setting Restart=always so a crash does not leave it down"
        DROPIN="/etc/systemd/system/${UNIT}.d"
        if [ "$DRY_RUN" -eq 0 ]; then
            mkdir -p "$DROPIN"
            cat > "$DROPIN/10-autorestart.conf" <<'CONF'
[Service]
Restart=always
RestartSec=5
# Survive the OOM killer: restart instead of staying dead.
OOMPolicy=continue
CONF
            systemctl daemon-reload
            ok "drop-in written to $DROPIN/10-autorestart.conf"
        fi
        FIXES+=("Restart=always for $UNIT")
    fi
elif [ -n "$CREATE_UNIT" ]; then
    act "creating a systemd unit for: $CREATE_UNIT"
    if [ "$DRY_RUN" -eq 0 ]; then
        cat > "/etc/systemd/system/${AGENT}.service" <<CONF
[Unit]
Description=${AGENT} agent
After=network-online.target

[Service]
Type=simple
ExecStart=${CREATE_UNIT}
Restart=always
RestartSec=5
OOMPolicy=continue

[Install]
WantedBy=multi-user.target
CONF
        systemctl daemon-reload
        systemctl enable "${AGENT}.service" >/dev/null 2>&1
        UNIT="${AGENT}.service"
        ok "created and enabled ${AGENT}.service"
    fi
    FIXES+=("created ${AGENT}.service")
elif [ "$HAS_SYSTEMD" -eq 1 ]; then
    warn "no unit for $AGENT, so nothing supervises it"
    echo "     re-run with: --create-unit '/full/path/to/hermes --your --flags'"
fi

# 3. start it
if [ -n "$UNIT" ]; then
    act "restarting $UNIT"
    run systemctl restart "$UNIT"
    FIXES+=("restarted $UNIT")
fi

# ---------------------------------------------------------------- verify
hr "Verify"
if [ "$DRY_RUN" -eq 1 ]; then
    warn "dry run -- nothing was changed, nothing to verify"
elif [ -n "$UNIT" ]; then
    echo "  watching for ${SETTLE}s to catch a crash loop..."
    BEFORE_RESTARTS=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null || echo 0)
    HEALTHY=1
    for i in $(seq 1 "$SETTLE"); do
        sleep 1
        STATE=$(systemctl is-active "$UNIT" 2>/dev/null)
        if [ "$STATE" = "failed" ]; then HEALTHY=0; break; fi
        [ $((i % 5)) -eq 0 ] && printf '    %2ss: %s\n' "$i" "$STATE"
    done
    AFTER_RESTARTS=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null || echo 0)
    STATE=$(systemctl is-active "$UNIT" 2>/dev/null)

    if [ "$STATE" = "active" ] && [ "${AFTER_RESTARTS:-0}" -le "${BEFORE_RESTARTS:-0}" ]; then
        ok "$UNIT is active and stable for ${SETTLE}s"
    elif [ "$STATE" = "active" ]; then
        bad "$UNIT is up but restarted $((AFTER_RESTARTS - BEFORE_RESTARTS))x while watching -- crash loop"
        HEALTHY=0
    else
        bad "$UNIT is $STATE"
        HEALTHY=0
    fi

    if [ "$HEALTHY" -eq 0 ]; then
        echo "  failure output:"
        journalctl -u "$UNIT" -n 20 --no-pager 2>/dev/null | tail -20 | cut -c1-120 | sed 's/^/    /'
    fi
else
    warn "no unit to verify; check your agent by hand"
fi

# ---------------------------------------------------------------- summary
hr "Summary"
if [ ${#PROBLEMS[@]} -eq 0 ]; then
    echo "  Found nothing wrong."
else
    echo "  Problems found:"
    printf '    - %s\n' "${PROBLEMS[@]}"
fi
if [ ${#FIXES[@]} -eq 0 ]; then
    echo "  Changed nothing."
else
    echo "  Applied:"
    printf '    - %s\n' "${FIXES[@]}"
fi
printf '\n  RAM %sM | swap now %sM\n' "$TOTAL_MB" "$(( $(meminfo SwapTotal) / 1024 ))"
if [ -n "$UNIT" ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "  $UNIT: $(systemctl is-active "$UNIT" 2>/dev/null)"
    echo "  follow it live:  journalctl -u $UNIT -f"
fi
