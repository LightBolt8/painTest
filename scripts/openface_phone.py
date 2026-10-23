#!/usr/bin/env python3
"""Start OpenFace bridge + Cloudflare tunnel for physical iPhone (any network).

Usage:
  python3 scripts/openface_phone.py

Copy the printed https://….trycloudflare.com URL into the app:
  Settings → OpenFace server URL
"""

from __future__ import annotations

import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "scripts" / "openface_server.py"
URL_FILE = ROOT / "scripts" / "CURRENT_OPENFACE_URL.txt"
CF = Path("/opt/homebrew/bin/cloudflared")
PORT = 8765


def main() -> None:
    if not CF.exists():
        raise SystemExit("cloudflared missing. Run: brew install cloudflared")

    server = subprocess.Popen(
        [sys.executable, str(SERVER)],
        cwd=str(ROOT),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )
    time.sleep(1.5)
    if server.poll() is not None:
        raise SystemExit("OpenFace server failed to start on port 8765")

    # Log to a file so cloudflared output isn't line-buffered behind a pipe.
    log_path = Path("/tmp/cloudflared_tunnel.log")
    log_file = open(log_path, "w")
    tunnel = subprocess.Popen(
        [str(CF), "tunnel", "--url", f"http://127.0.0.1:{PORT}"],
        stdout=log_file,
        stderr=subprocess.STDOUT,
        text=True,
    )

    url = None
    try:
        for _ in range(60):
            time.sleep(0.5)
            if tunnel.poll() is not None:
                log_file.flush()
                raise SystemExit(f"cloudflared exited early. See {log_path}")
            text = log_path.read_text(errors="ignore")
            match = re.search(r"https://[a-zA-Z0-9.-]+\.trycloudflare\.com", text)
            if match:
                url = match.group(0)
                URL_FILE.write_text(url + "\n")
                # Keep app default in sync so Settings → “Use live server URL” works after rebuild.
                swift = ROOT / "painTest" / "OpenFaceAnalyzer.swift"
                if swift.exists():
                    text = swift.read_text()
                    updated = re.sub(
                        r'static let suggestedHost = "https://[^"]+\.trycloudflare\.com"',
                        f'static let suggestedHost = "{url}"',
                        text,
                        count=1,
                    )
                    if updated != text:
                        swift.write_text(updated)
                print("=" * 60, flush=True)
                print("Paste this into painTest → Settings → OpenFace server URL:", flush=True)
                print(f"  {url}", flush=True)
                print(f"(also saved to {URL_FILE.name})", flush=True)
                print("=" * 60, flush=True)
                print(f"Tunnel running. Keep this terminal open. Log: {log_path}", flush=True)
                break
        else:
            raise SystemExit(f"No trycloudflare URL after 30s. See {log_path}")

        tunnel.wait()
    except KeyboardInterrupt:
        print("\nStopping…")
    finally:
        tunnel.terminate()
        server.terminate()
        log_file.close()
        try:
            tunnel.wait(timeout=3)
            server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            tunnel.kill()
            server.kill()


if __name__ == "__main__":
    main()
