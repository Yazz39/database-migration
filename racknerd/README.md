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
