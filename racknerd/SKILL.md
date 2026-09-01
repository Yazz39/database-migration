---
name: racknerd-vps-api
description: Control a RackNerd VPS through the SolusVM client API. Status, info, power actions, hostname, root password, serial console, VNC. Credentials stay in the environment, never in code.
license: MIT
compatibility: universal
metadata:
  agents:
    - opencode
    - claude-code
    - cursor
    - copilot
    - cline
    - kilo
    - hermes
    - openclaw
  category: infrastructure
  tags:
    - racknerd
    - solusvm
    - vps
    - api
    - infrastructure
    - server-management
  version: 1.0.0
---

# RackNerd VPS API Skill

## Capabilities

Drive a RackNerd VPS from the command line or from an agent:

1. **Health checks**: power state, IPs, disk, memory, bandwidth
2. **Power control**: boot, reboot, shutdown — with confirmation guards
3. **Recovery**: root password reset, serial console, VNC details
4. **Configuration**: hostname changes
5. **Escape hatch**: `raw` passes any SolusVM action through

## Setup

Three environment variables, from the SolusVM panel's API tab:

```bash
export RACKNERD_API_URL="https://<panel-host>/api/client/command.php"
export RACKNERD_API_KEY="..."
export RACKNERD_API_HASH="..."
python3 racknerd.py test
```

See `README.md` for where each value lives and `.env.example` for the file
form.

## Commands

| Command | Effect |
|---------|--------|
| `test` | Verify credentials and reachability |
| `status` | Power state |
| `info [--full]` | Server details, optionally with IPs/disk/memory/bandwidth |
| `boot` / `reboot` / `shutdown` | Power actions (confirm, or `--yes`) |
| `hostname NAME` | Change hostname |
| `rootpassword` | Reset root password (prompts) |
| `console [--hours N] [--disable]` | Serial console access |
| `vnc` | VNC connection details |
| `raw ACTION key=value...` | Any other SolusVM client action |

## Guardrails

- Credentials are sent as POST fields, never in a URL.
- Non-HTTPS endpoints are refused.
- Destructive actions require an interactive confirmation or `--yes`.
- Printed credentials are always masked.
- Nothing is written to the repository; `.env` is gitignored.

## Agent usage

Ask your agent:

- "Is my RackNerd VPS up?"
- "Show my VPS bandwidth usage this month"
- "Reboot the VPS"
- "Enable the serial console for two hours"
