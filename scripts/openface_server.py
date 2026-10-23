#!/usr/bin/env python3
"""OpenFace (+ optional FaceFusion de-age) bridge for the painTest app.

Usage:
  python3 scripts/openface_server.py

Headers for /analyze:
  X-PainTest-Estimate-Age: 1         # include apparent age in a JSON response
  X-PainTest-Deage: 1
  X-PainTest-Target-Age: 25          # de-age toward this age, re-checking after each pass (max 2);
                                     # skipped if already within AGE_TOLERANCE_YEARS of it
  X-PainTest-Source-Age: 54          # person's real age (from Settings); years to subtract = target − source
  X-PainTest-Deage-Direction: -60    # legacy: years relative to the estimated age, -100..100

POST /deage — FaceFusion age preview only (returns image/jpeg).
  X-PainTest-Deage-Direction: -60
"""

from __future__ import annotations

import base64
import csv
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "OpenFace" / "build" / "bin"
FEATURE = BIN / "FeatureExtraction"
DEAGE = ROOT / "scripts" / "deage_face.py"
ESTIMATE_AGE = ROOT / "scripts" / "estimate_age.py"
PORT = 8765
DEFAULT_DEAGE_DIRECTION = -60
# Faces within this many years of the target are left alone (fairface's spread is ~4-9 years).
AGE_TOLERANCE_YEARS = 6
MAX_DEAGE_PASSES = 2
MIN_PASS_GAIN_YEARS = 3
PSPI_AUS = ["AU04_r", "AU06_r", "AU07_r", "AU09_r", "AU10_r", "AU45_r"]

ENV = os.environ.copy()
ENV["OMP_NUM_THREADS"] = "1"
ENV["VECLIB_MAXIMUM_THREADS"] = "1"
ENV["DYLD_LIBRARY_PATH"] = ":".join(
    [
        "/opt/homebrew/opt/opencv@4/lib",
        "/opt/homebrew/opt/openblas/lib",
        "/opt/homebrew/lib",
        ENV.get("DYLD_LIBRARY_PATH", ""),
    ]
)


def lan_ips() -> list[str]:
    ips: list[str] = []
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ips.append(sock.getsockname()[0])
        sock.close()
    except OSError:
        pass
    for iface_cmd in (
        ["ipconfig", "getifaddr", "en0"],
        ["ipconfig", "getifaddr", "en1"],
    ):
        try:
            out = subprocess.check_output(iface_cmd, text=True, stderr=subprocess.DEVNULL).strip()
            if out and out not in ips:
                ips.append(out)
        except (OSError, subprocess.CalledProcessError):
            pass
    return ips


def truthy(value: str | None) -> bool:
    if not value:
        return False
    return value.strip().lower() in {"1", "true", "yes", "on"}


def parse_direction(raw: str | None) -> int:
    try:
        value = int((raw or str(DEFAULT_DEAGE_DIRECTION)).strip())
    except ValueError:
        value = DEFAULT_DEAGE_DIRECTION
    return max(-100, min(100, value))


def parse_target_age(raw: str | None) -> int | None:
    if not raw:
        return None
    try:
        value = int(raw.strip())
    except ValueError:
        return None
    return max(1, min(100, value))


def run_estimate_age(image_path: Path) -> dict | None:
    """Apparent age band from FaceFusion's fairface classifier, or None if it can't tell."""
    if not ESTIMATE_AGE.exists():
        return None
    proc = subprocess.run(
        [sys.executable, str(ESTIMATE_AGE), str(image_path)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    lines = [line for line in proc.stdout.splitlines() if line.strip().startswith("{")]
    if not lines:
        return None
    try:
        data = json.loads(lines[-1])
    except json.JSONDecodeError:
        return None
    if proc.returncode != 0 or "error" in data:
        return None
    return data


def run_openface(image_path: Path, out_dir: Path) -> bytes:
    proc = subprocess.run(
        [
            str(FEATURE),
            "-f",
            str(image_path),
            "-out_dir",
            str(out_dir),
            "-aus",
            "-pose",
            "-au_static",
            "-q",
        ],
        cwd=str(BIN),
        env=ENV,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr[-500:] or "OpenFace failed")
    csvs = list(out_dir.glob("*.csv"))
    if not csvs:
        raise RuntimeError("No CSV produced")
    return csvs[0].read_bytes()


def run_deage(image_bytes: bytes, direction: int, work: Path) -> bytes:
    if not DEAGE.exists():
        raise RuntimeError(f"Missing de-age script at {DEAGE}")
    inp = work / "deage_in.jpg"
    out = work / "deage_out.jpg"
    inp.write_bytes(image_bytes)
    proc = subprocess.run(
        [
            sys.executable,
            str(DEAGE),
            str(inp),
            str(out),
            "--direction",
            str(direction),
        ],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not out.is_file():
        raise RuntimeError((proc.stderr or proc.stdout or "De-age failed")[-800:])
    return out.read_bytes()


def run_deage_to_target(
    original: bytes, age: dict, target_age: int, work: Path
) -> tuple[bytes, dict | None, int, int]:
    """De-age toward target_age, re-measuring after each pass because FRAN under-shoots.

    Each pass costs expression fidelity, so this stops once the face is within
    AGE_TOLERANCE_YEARS of the target, after MAX_DEAGE_PASSES, or when a pass stops helping.
    Returns (image, age after, passes run, total years requested).
    """
    image, current = original, age
    passes = total = 0
    while passes < MAX_DEAGE_PASSES and current["age_estimate"] > target_age + AGE_TOLERANCE_YEARS:
        # FRAN treats its own band midpoint as the starting age, so aim relative to that.
        direction = max(-100, min(100, round(target_age - current.get("fran_source_age", current["age_estimate"]))))
        if direction >= 0:
            break
        candidate = run_deage(image, direction, work)
        probe = work / f"pass{passes + 1}.jpg"
        probe.write_bytes(candidate)
        after = run_estimate_age(probe)
        if passes > 0 and (after is None or current["age_estimate"] - after["age_estimate"] < MIN_PASS_GAIN_YEARS):
            break
        image, passes, total = candidate, passes + 1, total + direction
        if after is None:
            current = None
            break
        current = after
    return image, (current if passes else None), passes, total


def read_au_intensities(csv_bytes: bytes) -> dict[str, float]:
    rows = list(csv.DictReader(io.StringIO(csv_bytes.decode("utf-8", errors="replace")), skipinitialspace=True))
    if not rows:
        return {}
    values = {}
    for key, raw in rows[0].items():
        if key and key.strip().endswith("_r"):
            try:
                values[key.strip()] = float(raw)
            except (TypeError, ValueError):
                pass
    return values


def expression_drift(original_csv: bytes, normalized_csv: bytes) -> float | None:
    """Mean absolute change (0-5 scale) in the PSPI Action Units caused by de-aging."""
    before, after = read_au_intensities(original_csv), read_au_intensities(normalized_csv)
    diffs = [abs(before[k] - after[k]) for k in PSPI_AUS if k in before and k in after]
    return round(sum(diffs) / len(diffs), 3) if diffs else None


def sanitize_error(message: str, limit: int = 180) -> str:
    text = " ".join(str(message).split())
    return text[:limit] if text else "request failed"


def send_plain_error(handler: BaseHTTPRequestHandler, code: int, message: str) -> None:
    body = sanitize_error(message).encode("utf-8", errors="replace")
    handler.send_response(code)
    handler.send_header("Content-Type", "text/plain; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        path = urlparse(self.path).path
        if path in ("/", "/health"):
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/deage":
            self.handle_deage(parsed)
            return
        if parsed.path != "/analyze":
            send_plain_error(self, 404, "Not found")
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if not body:
            send_plain_error(self, 400, "Empty body")
            return
        if not FEATURE.exists():
            send_plain_error(self, 500, f"Missing OpenFace binary at {FEATURE}")
            return

        query = parse_qs(parsed.query)
        deage = truthy(self.headers.get("X-PainTest-Deage")) or truthy(
            (query.get("deage") or [None])[0]
        )
        direction = parse_direction(
            self.headers.get("X-PainTest-Deage-Direction")
            or (query.get("direction") or [None])[0]
        )
        target_age = parse_target_age(self.headers.get("X-PainTest-Target-Age"))
        source_age = parse_target_age(self.headers.get("X-PainTest-Source-Age"))
        want_age = truthy(self.headers.get("X-PainTest-Estimate-Age")) or (
            target_age is not None and source_age is None
        )

        try:
            with tempfile.TemporaryDirectory(prefix="paintest-of-") as tmp:
                tmp_path = Path(tmp)
                original_path = tmp_path / "original.jpg"
                original_path.write_bytes(body)

                age = run_estimate_age(original_path) if want_age else None

                skip_reason = None
                image_bytes = body
                deaged_age = None
                passes = 0
                total_direction = 0
                if deage and target_age is not None:
                    start = None
                    if source_age is not None:
                        start = {
                            "age_low": source_age,
                            "age_high": source_age,
                            "age_estimate": float(source_age),
                            "fran_source_age": float(source_age),
                        }
                    elif age is not None:
                        start = age
                    if start is None:
                        skip_reason = "age_unknown"
                    elif start["age_estimate"] <= target_age + AGE_TOLERANCE_YEARS:
                        skip_reason = "at_or_below_target"
                    else:
                        image_bytes, deaged_age, passes, total_direction = run_deage_to_target(
                            body, start, target_age, tmp_path
                        )
                        if passes == 0:
                            skip_reason = "at_or_below_target"
                elif deage:
                    image_bytes = run_deage(body, direction, tmp_path)
                    passes, total_direction = 1, direction
                will_deage = passes > 0

                image_path = tmp_path / "input.jpg"
                out_dir = tmp_path / "out"
                out_dir.mkdir()
                image_path.write_bytes(image_bytes)
                csv_payload = run_openface(image_path, out_dir)

                original_csv = None
                if will_deage:
                    original_out = tmp_path / "out_original"
                    original_out.mkdir()
                    original_csv = run_openface(original_path, original_out)
                    if want_age and deaged_age is None:
                        deaged_age = run_estimate_age(image_path)

                if deage or want_age:
                    response = {
                        "csv": csv_payload.decode("utf-8", errors="replace"),
                        "deaged": will_deage,
                        "direction": total_direction if will_deage else 0,
                        "passes": passes,
                        "target_age": target_age,
                        "age": age,
                        "deaged_age": deaged_age,
                        "deage_skipped": skip_reason,
                    }
                    if will_deage:
                        response["image_base64"] = base64.b64encode(image_bytes).decode("ascii")
                        response["original_csv"] = original_csv.decode("utf-8", errors="replace")
                        response["expression_drift"] = expression_drift(original_csv, csv_payload)
                    payload = json.dumps(response).encode("utf-8")
                    content_type = "application/json"
                else:
                    payload = csv_payload
                    content_type = "text/csv"
        except Exception as exc:  # noqa: BLE001
            send_plain_error(self, 500, str(exc))
            return

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def handle_deage(self, parsed) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if not body:
            send_plain_error(self, 400, "Empty body")
            return
        query = parse_qs(parsed.query)
        direction = parse_direction(
            self.headers.get("X-PainTest-Deage-Direction")
            or (query.get("direction") or [None])[0]
        )
        try:
            with tempfile.TemporaryDirectory(prefix="paintest-deage-") as tmp:
                out = run_deage(body, direction, Path(tmp))
        except Exception as exc:  # noqa: BLE001
            send_plain_error(self, 500, str(exc))
            return

        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("X-PainTest-Deage-Direction", str(direction))
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, fmt: str, *args) -> None:
        print(f"[openface_server] {self.address_string()} - {fmt % args}")


def start_helpers() -> None:
    """Keep the Mac awake and advertise the bridge on the LAN while this process lives.

    Both helpers watch our PID and exit with us, so they never outlive the server.
    """
    pid = os.getpid()
    try:
        subprocess.Popen(
            ["caffeinate", "-i", "-w", str(pid)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print("Sleep prevention: on (caffeinate)")
    except FileNotFoundError:
        print("Sleep prevention: caffeinate not found")

    # dns-sd has no -w flag, so a shell loop kills it when the server exits.
    advertise = (
        f'dns-sd -R "painTest OpenFace" _paintest._tcp local {PORT} >/dev/null 2>&1 & D=$!; '
        f"while kill -0 {pid} 2>/dev/null; do sleep 3; done; kill $D"
    )
    try:
        subprocess.Popen(
            ["/bin/sh", "-c", advertise],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print("Same Wi-Fi discovery: advertising _paintest._tcp")
    except FileNotFoundError:
        print("Same Wi-Fi discovery: dns-sd not available")


def main() -> None:
    if not FEATURE.exists():
        raise SystemExit(f"OpenFace binary missing: {FEATURE}")

    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    start_helpers()
    ips = lan_ips() or ["<your-mac-lan-ip>"]
    print(f"OpenFace bridge listening on port {PORT}")
    print(f"Using {FEATURE}")
    print(f"FaceFusion de-age script: {DEAGE} ({'ready' if DEAGE.exists() else 'missing'})")
    print("")
    print("On your iPhone, set Settings → OpenFace server URL to the tunnel / LAN address.")
    for ip in ips:
        print(f"  {ip}")
    print("")
    print(f"Health check: http://{ips[0]}:{PORT}/health")
    server.serve_forever()


if __name__ == "__main__":
    main()
