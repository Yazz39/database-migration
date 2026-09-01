#!/usr/bin/env python3
"""RackNerd VPS control via the SolusVM client API.

Zero dependencies (stdlib only). Credentials are read from the environment or
an untracked .env file -- never from the command line, so they stay out of
shell history and process listings.

Configuration:
    RACKNERD_API_URL   full client API endpoint, e.g.
                       https://panel.example.com/api/client/command.php
    RACKNERD_API_KEY   the "API Key" from your SolusVM panel
    RACKNERD_API_HASH  the "API Hash" from your SolusVM panel

Examples:
    racknerd.py test
    racknerd.py status
    racknerd.py info --full --json
    racknerd.py reboot --yes
    racknerd.py console --enable --hours 2
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

EXIT_OK = 0
EXIT_API_ERROR = 1
EXIT_CONFIG_ERROR = 2
EXIT_NETWORK_ERROR = 3

DEFAULT_TIMEOUT = 30
ENV_FILES = (".env", os.path.expanduser("~/.config/racknerd/env"))

# Actions that change the state of a running server.
DESTRUCTIVE = {"reboot", "shutdown", "boot", "rootpassword", "hostname"}


class ConfigError(Exception):
    pass


class ApiError(Exception):
    def __init__(self, message: str, payload: dict | None = None):
        super().__init__(message)
        self.payload = payload or {}


def mask(secret: str) -> str:
    """Show enough of a credential to identify it, never enough to use it."""
    if not secret:
        return "(unset)"
    if len(secret) <= 8:
        return "*" * len(secret)
    return f"{secret[:4]}{'*' * (len(secret) - 8)}{secret[-4:]}"


def load_env_files() -> None:
    """Populate os.environ from the first .env file found. Real env wins."""
    for path in ENV_FILES:
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip().strip("'\"")
                os.environ.setdefault(key, value)
        return


def get_config(url_override: str | None = None) -> tuple[str, str, str]:
    load_env_files()
    url = url_override or os.environ.get("RACKNERD_API_URL", "").strip()
    key = os.environ.get("RACKNERD_API_KEY", "").strip()
    api_hash = os.environ.get("RACKNERD_API_HASH", "").strip()

    missing = [
        name
        for name, value in (
            ("RACKNERD_API_URL", url),
            ("RACKNERD_API_KEY", key),
            ("RACKNERD_API_HASH", api_hash),
        )
        if not value
    ]
    if missing:
        raise ConfigError(
            "Missing credentials: "
            + ", ".join(missing)
            + "\nSet them in your shell or in an untracked .env file "
            "(see racknerd/.env.example)."
        )
    if not url.startswith("https://"):
        raise ConfigError(
            f"RACKNERD_API_URL must use https:// (got {url!r}). "
            "The API key and hash are sent in the request body; plain HTTP "
            "would expose them."
        )
    return url, key, api_hash


def parse_response(body: str) -> dict:
    """SolusVM answers as JSON with rdtype=json, else <tag>value</tag>."""
    body = body.strip()
    if not body:
        raise ApiError("Empty response from API")

    if body.startswith("{") or body.startswith("["):
        try:
            parsed = json.loads(body)
            return parsed if isinstance(parsed, dict) else {"result": parsed}
        except json.JSONDecodeError:
            pass

    tags = dict(re.findall(r"<([^/>]+)>(.*?)</\1>", body, re.DOTALL))
    if tags:
        return {k.strip(): v.strip() for k, v in tags.items()}

    kv = dict(
        line.split("=", 1)
        for line in body.splitlines()
        if "=" in line and not line.startswith("#")
    )
    if kv:
        return {k.strip(): v.strip() for k, v in kv.items()}

    raise ApiError(f"Unrecognized response format: {body[:200]}")


def call(action: str, params: dict | None = None, *, url_override: str | None = None,
         timeout: int = DEFAULT_TIMEOUT) -> dict:
    """POST one command to the SolusVM client API and return the parsed result."""
    url, key, api_hash = get_config(url_override)

    payload = {
        "key": key,
        "hash": api_hash,
        "action": action,
        "rdtype": "json",
    }
    payload.update({k: v for k, v in (params or {}).items() if v is not None})

    data = urllib.parse.urlencode(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,  # POST body, so credentials never land in URLs or access logs
        method="POST",
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "racknerd-cli/1.0",
            "Accept": "application/json, text/plain, */*",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:300]
        raise ApiError(f"HTTP {exc.code} from API: {detail}") from exc
    except urllib.error.URLError as exc:
        raise ApiError(f"Could not reach {url}: {exc.reason}") from exc
    except TimeoutError as exc:
        raise ApiError(f"Request to {url} timed out after {timeout}s") from exc

    result = parse_response(body)
    if str(result.get("status", "success")).lower() == "error":
        message = result.get("statusmsg") or result.get("statusmessage") or "unknown error"
        raise ApiError(f"API rejected '{action}': {message}", result)
    return result


def render(result: dict, as_json: bool) -> None:
    if as_json:
        print(json.dumps(result, indent=2, sort_keys=True))
        return
    width = max((len(k) for k in result), default=0)
    for key in sorted(result):
        print(f"{key.ljust(width)}  {result[key]}")


def confirm(action: str, assume_yes: bool) -> bool:
    if assume_yes or action not in DESTRUCTIVE:
        return True
    if not sys.stdin.isatty():
        print(
            f"Refusing to run '{action}' non-interactively without --yes.",
            file=sys.stderr,
        )
        return False
    answer = input(f"Run '{action}' against your VPS? [y/N] ").strip().lower()
    return answer in {"y", "yes"}


def cmd_test(args: argparse.Namespace) -> int:
    url, key, api_hash = get_config(args.url)
    print(f"endpoint  {url}")
    print(f"key       {mask(key)}")
    print(f"hash      {mask(api_hash)}")
    result = call("status", url_override=args.url, timeout=args.timeout)
    print("\nConnection OK.\n")
    render(result, args.json)
    return EXIT_OK


def cmd_status(args: argparse.Namespace) -> int:
    render(call("status", url_override=args.url, timeout=args.timeout), args.json)
    return EXIT_OK


def cmd_info(args: argparse.Namespace) -> int:
    params = {"status": "true"}
    if args.full:
        params.update({"ipaddr": "true", "hdd": "true", "mem": "true", "bw": "true"})
    render(call("info", params, url_override=args.url, timeout=args.timeout), args.json)
    return EXIT_OK


def cmd_power(args: argparse.Namespace) -> int:
    if not confirm(args.action, args.yes):
        return EXIT_API_ERROR
    render(call(args.action, url_override=args.url, timeout=args.timeout), args.json)
    return EXIT_OK


def cmd_hostname(args: argparse.Namespace) -> int:
    if not confirm("hostname", args.yes):
        return EXIT_API_ERROR
    result = call(
        "hostname",
        {"hostname": args.hostname},
        url_override=args.url,
        timeout=args.timeout,
    )
    render(result, args.json)
    return EXIT_OK


def cmd_rootpassword(args: argparse.Namespace) -> int:
    # Prompted, never passed as an argv value that lands in shell history.
    password = getpass.getpass("New root password: ")
    if password != getpass.getpass("Confirm: "):
        print("Passwords do not match.", file=sys.stderr)
        return EXIT_CONFIG_ERROR
    if not confirm("rootpassword", args.yes):
        return EXIT_API_ERROR
    result = call(
        "rootpassword",
        {"rootpassword": password},
        url_override=args.url,
        timeout=args.timeout,
    )
    render(result, args.json)
    return EXIT_OK


def cmd_console(args: argparse.Namespace) -> int:
    params = {"access": "disable" if args.disable else "enable"}
    if not args.disable:
        params["time"] = str(args.hours)
    render(
        call("console", params, url_override=args.url, timeout=args.timeout),
        args.json,
    )
    return EXIT_OK


def cmd_vnc(args: argparse.Namespace) -> int:
    render(call("vnc", url_override=args.url, timeout=args.timeout), args.json)
    return EXIT_OK


def cmd_raw(args: argparse.Namespace) -> int:
    params = {}
    for pair in args.params:
        if "=" not in pair:
            print(f"Bad parameter {pair!r}; expected key=value.", file=sys.stderr)
            return EXIT_CONFIG_ERROR
        key, _, value = pair.partition("=")
        params[key] = value
    if not confirm(args.action, args.yes):
        return EXIT_API_ERROR
    render(
        call(args.action, params, url_override=args.url, timeout=args.timeout),
        args.json,
    )
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="racknerd.py",
        description="Control a RackNerd VPS through the SolusVM client API.",
        epilog="Credentials come from RACKNERD_API_KEY / RACKNERD_API_HASH "
               "(env or untracked .env), never from the command line.",
    )
    parser.add_argument("--url", help="override RACKNERD_API_URL for one call")
    parser.add_argument("--json", action="store_true", help="print raw JSON")
    parser.add_argument(
        "--timeout", type=int, default=DEFAULT_TIMEOUT, help="seconds (default 30)"
    )
    parser.add_argument(
        "-y", "--yes", action="store_true", help="skip confirmation prompts"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("test", help="verify credentials and reachability").set_defaults(
        func=cmd_test
    )
    sub.add_parser("status", help="power state of the VPS").set_defaults(func=cmd_status)

    info = sub.add_parser("info", help="server details")
    info.add_argument(
        "--full", action="store_true", help="include IPs, disk, memory, bandwidth"
    )
    info.set_defaults(func=cmd_info)

    for action, help_text in (
        ("boot", "power on"),
        ("reboot", "restart"),
        ("shutdown", "power off"),
    ):
        power = sub.add_parser(action, help=help_text)
        power.set_defaults(func=cmd_power, action=action)

    hostname = sub.add_parser("hostname", help="change the hostname")
    hostname.add_argument("hostname")
    hostname.set_defaults(func=cmd_hostname)

    sub.add_parser(
        "rootpassword", help="change the root password (prompts)"
    ).set_defaults(func=cmd_rootpassword)

    console = sub.add_parser("console", help="serial console access")
    console.add_argument("--hours", type=int, default=1, choices=range(1, 9))
    console.add_argument("--disable", action="store_true", help="revoke access")
    console.set_defaults(func=cmd_console)

    sub.add_parser("vnc", help="VNC connection details").set_defaults(func=cmd_vnc)

    raw = sub.add_parser("raw", help="send an arbitrary action")
    raw.add_argument("action")
    raw.add_argument("params", nargs="*", metavar="key=value")
    raw.set_defaults(func=cmd_raw)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except ConfigError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        return EXIT_CONFIG_ERROR
    except ApiError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return EXIT_API_ERROR
    except KeyboardInterrupt:
        return EXIT_NETWORK_ERROR


if __name__ == "__main__":
    sys.exit(main())
