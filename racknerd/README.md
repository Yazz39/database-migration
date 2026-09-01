# RackNerd VPS API Client

A zero-dependency CLI for controlling a RackNerd VPS through the SolusVM
client API. Python 3.8+, stdlib only — no `pip install` step.

## Configuration

Credentials are read from the environment, or from an untracked `.env` file
in the working directory (or `~/.config/racknerd/env`). They are never
accepted as command-line arguments, so they stay out of shell history and
`ps` output.

```bash
cp racknerd/.env.example .env
$EDITOR .env          # fill in URL, key, hash
```

Or export them directly:

```bash
export RACKNERD_API_URL="https://your-panel-host/api/client/command.php"
export RACKNERD_API_KEY="..."
export RACKNERD_API_HASH="..."
```

### Finding the three values

| Value | Where it comes from |
|-------|---------------------|
| `RACKNERD_API_URL` | Your SolusVM panel hostname (in the RackNerd welcome email, listed as "VPS Control Panel") plus `/api/client/command.php`. Some installs serve it on port `5656`. |
| `RACKNERD_API_KEY` | SolusVM panel → select your VPS → **API** tab → enable API access |
| `RACKNERD_API_HASH` | Same page as the key |

Verify all three at once:

```bash
python3 racknerd/racknerd.py test
```

This prints the endpoint and *masked* credentials, then makes one read-only
`status` call. Exit code `0` means the credentials work.

## Commands

```bash
racknerd.py test                      # verify credentials + reachability
racknerd.py status                    # power state
racknerd.py info                      # server details
racknerd.py info --full               # + IPs, disk, memory, bandwidth
racknerd.py boot --yes                # power on
racknerd.py reboot --yes              # restart
racknerd.py shutdown --yes            # power off
racknerd.py hostname vps01.example.com --yes
racknerd.py rootpassword              # prompts, never echoes
racknerd.py console --hours 2         # enable serial console for 2h
racknerd.py console --disable         # revoke console access
racknerd.py vnc                       # VNC connection details
racknerd.py raw <action> key=value... # any other SolusVM action
```

Global flags: `--json` (machine-readable output), `--url` (override the
endpoint for one call), `--timeout` (default 30s), `-y/--yes` (skip the
confirmation prompt).

### Scripting

`--json` plus exit codes makes this safe to drive from other tools:

```bash
if state=$(racknerd.py --json status); then
  echo "$state" | jq -r '.vmstat'
fi
```

| Exit code | Meaning |
|-----------|---------|
| 0 | success |
| 1 | the API rejected the request, or a destructive action was declined |
| 2 | missing or invalid configuration |
| 3 | interrupted |

## What this API cannot do

The SolusVM client API talks to the **hypervisor**, not to the operating
system inside your VPS. There is no "run a command in the guest" action, so
the API cannot:

- clear cache memory, flush buffers, or free RAM
- restart a service, tail a log, or inspect a process
- read or write files on the VPS

Anything inside the guest needs shell access. The API's only lever over
in-guest state is `reboot`, which clears RAM by restarting everything.

### `fix-hermes.sh` — repair, then verify

Diagnoses why the agent keeps dying, fixes the usual causes, and watches it
for 20s to confirm it stays up rather than crash-looping.

```bash
sudo bash fix-hermes.sh --dry-run     # show the plan, change nothing
sudo bash fix-hermes.sh               # diagnose, repair, verify
sudo bash fix-hermes.sh --agent NAME  # if the service is not called "hermes"
```

What it repairs:

| Problem | Fix |
|---------|-----|
| No swap on a small VPS | Creates a right-sized swapfile, persists it in `/etc/fstab`, sets `vm.swappiness=10` |
| Service dies and stays dead | systemd drop-in with `Restart=always`, `RestartSec=5`, `OOMPolicy=continue` |
| No service at all | `--create-unit '/path/to/hermes --flags'` writes and enables a unit |
| Disk full | Reports the biggest directories — deletes nothing on its own |

It reports what it found and what it changed, and prints the failing log
lines if the agent still will not stay up.

**Why swap first:** a budget VPS with 1–2GB RAM and no swap gives the kernel
no option but to OOM-kill the largest process when an agent spikes. That
process is usually the agent. Swap turns a fatal kill into a slow moment.

### `vps-diagnose.sh`

For in-guest work, `vps-diagnose.sh` runs **on the VPS** over SSH:

```bash
scp racknerd/vps-diagnose.sh you@your-vps:/tmp/
ssh you@your-vps 'sudo bash /tmp/vps-diagnose.sh'                  # report only
ssh you@your-vps 'sudo bash /tmp/vps-diagnose.sh --drop-caches'    # reclaim if needed
ssh you@your-vps 'sudo bash /tmp/vps-diagnose.sh --agent hermes'   # check your agent
```

It reports load, memory, swap, top consumers, OOM kills, disk, and your
agent's service state, then tells you which of those is actually the
problem.

On cache specifically: `--drop-caches` **declines to act** when memory is
healthy, because a large page cache is not a leak. Linux keeps recently read
files in otherwise-idle RAM and evicts them automatically the moment a
process needs the memory — `MemAvailable` already counts that cache as
free. Dropping it forces every subsequent read back to disk, so the usual
result is a slower server and an unchanged problem. Pass `--force` to
override the guard.

If an agent is unresponsive, the causes worth checking first are OOM kills,
swap thrash, a full disk, and the agent's own logs. The script surfaces all
four.

## Safety behavior

- **POST, not GET.** The key and hash travel in the request body, so they
  never appear in URLs, proxy logs, or server access logs.
- **HTTPS enforced.** A plain `http://` endpoint is rejected outright rather
  than sending credentials in the clear.
- **Destructive actions confirm.** `boot`, `reboot`, `shutdown`, `hostname`,
  and `rootpassword` prompt first, and refuse to run non-interactively
  unless `--yes` is passed.
- **Credentials are masked** in every line this tool prints.
- **Root passwords are prompted**, never read from `argv`.

## Credential hygiene

The API key and hash together grant full control of the VPS — reboot,
shutdown, root password reset. Treat them like a root password:

- Never commit them. The repo's `.gitignore` blocks `.env`.
- If they have ever been pasted into a chat, an issue, a log, or a shared
  document, **rotate them**: SolusVM panel → your VPS → API tab →
  regenerate. The old pair stops working immediately.
- Disable API access in the panel entirely when you are not using it.

## Testing

```bash
python3 -m unittest discover -s racknerd -v
```

The suite mocks the HTTP layer, so it runs offline and never touches a real
server.
