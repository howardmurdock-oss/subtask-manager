"""Stores the Cloudflare TURN key as Worker secrets, without echoing it.

Run from the project folder:
    python tool\\set_turn_secrets.py

Asks for the TURN key's ID and API token (typed or pasted, not shown),
checks them by asking Cloudflare for a short-lived TURN login, and only
then stores them as TURN_KEY_ID and TURN_KEY_API_TOKEN with exact bytes.
Piping secrets through PowerShell mangles them, which is why this exists.
"""

import getpass
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKER = os.path.join(ROOT, "worker")
ENV_FILE = os.path.join(ROOT, "cloudflare_env.ps1")


def cloudflare_env():
    env = dict(os.environ)
    with open(ENV_FILE, encoding="utf-8-sig") as f:
        for line in f:
            m = re.match(r"\s*\$env:([A-Z_]+)\s*=\s*'([^']*)'", line)
            if m:
                env[m.group(1)] = m.group(2)
    return env


def check(key_id, token):
    req = urllib.request.Request(
        f"https://rtc.live.cloudflare.com/v1/turn/keys/{key_id}/credentials/generate-ice-servers",
        data=json.dumps({"ttl": 300}).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            # Cloudflare turns away Python's default client name.
            "User-Agent": "subtask-manager-setup/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            body = json.loads(res.read())
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        sys.exit(f"Cloudflare refused that ID and token (HTTP {e.code}). Nothing was stored.\n"
                 f"Cloudflare said: {detail}")
    servers = body.get("iceServers") or []
    urls = [u for s in servers for u in (s.get("urls") if isinstance(s.get("urls"), list) else [s.get("urls")])]
    if not any(str(u).startswith("turn") for u in urls):
        sys.exit("Cloudflare answered, but without TURN servers. Nothing was stored.")
    print(f"Checked with Cloudflare: OK ({len(urls)} server addresses).")


def put(name, value, env):
    result = subprocess.run(
        ["npx.cmd" if os.name == "nt" else "npx", "wrangler", "secret", "put", name],
        input=value.encode("utf-8"),
        cwd=WORKER,
        env=env,
        capture_output=True,
    )
    if result.returncode != 0:
        sys.exit(f"Storing {name} failed:\n{result.stderr.decode(errors='replace')}")
    print(f"Stored {name}.")


def main():
    print("Nothing shows as you paste - that's deliberate. Paste with a RIGHT-CLICK, then press Enter.")
    key_id = getpass.getpass("TURN key ID (App ID): ").strip()
    print(f"  got {len(key_id)} characters")
    token = getpass.getpass("TURN API token: ").strip()
    print(f"  got {len(token)} characters")
    if not key_id or not token:
        sys.exit("Both are needed. Nothing was stored.")
    check(key_id, token)
    env = cloudflare_env()
    put("TURN_KEY_ID", key_id, env)
    put("TURN_KEY_API_TOKEN", token, env)
    print("Done.")


if __name__ == "__main__":
    main()
