#!/usr/bin/env python3
"""Run FaceFusion age_modifier (de-age) on a single image.

Usage:
  python3 scripts/deage_face.py input.jpg output.jpg [--direction -60]

Requires the conda env `facefusion` with FaceFusion installed under ./FaceFusion.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FF_ROOT = ROOT / "FaceFusion"
DEFAULT_DIRECTION = -60


def resolve_python() -> str:
    candidates = [
        Path("/opt/homebrew/Caskroom/miniconda/base/envs/facefusion/bin/python"),
        Path.home() / "miniconda3/envs/facefusion/bin/python",
        Path("/usr/local/Caskroom/miniconda/base/envs/facefusion/bin/python"),
        Path.home() / "mambaforge/envs/facefusion/bin/python",
    ]
    conda_prefix = os.environ.get("CONDA_PREFIX")
    if conda_prefix:
        base = Path(conda_prefix)
        if base.name == "facefusion":
            candidates.insert(0, base / "bin/python")
        else:
            candidates.insert(0, base.parent / "facefusion/bin/python")
            if (base / "envs/facefusion/bin/python").exists():
                candidates.insert(0, base / "envs/facefusion/bin/python")

    for path in candidates:
        if path.is_file():
            return str(path)
    return sys.executable


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("output")
    parser.add_argument("--direction", type=int, default=DEFAULT_DIRECTION)
    parser.add_argument("--model", default="fran")
    args = parser.parse_args()

    if not FF_ROOT.is_dir():
        raise SystemExit(f"FaceFusion missing at {FF_ROOT}")

    inp = Path(args.input).resolve()
    out = Path(args.output).resolve()
    if not inp.is_file():
        raise SystemExit(f"Input not found: {inp}")

    direction = max(-100, min(100, args.direction))
    python = resolve_python()
    env = os.environ.copy()
    env["KMP_DUPLICATE_LIB_OK"] = "TRUE"
    env["OMP_NUM_THREADS"] = "1"
    env["PYTHONPATH"] = str(FF_ROOT) + os.pathsep + env.get("PYTHONPATH", "")
    brew_ffmpeg = "/opt/homebrew/opt/ffmpeg/bin"
    if Path(brew_ffmpeg).is_dir():
        env["PATH"] = brew_ffmpeg + os.pathsep + env.get("PATH", "")

    cmd = [
        python,
        str(FF_ROOT / "facefusion.py"),
        "headless-run",
        "--target-path",
        str(inp),
        "--output-path",
        str(out),
        "--processors",
        "age_modifier",
        "--age-modifier-model",
        args.model,
        "--age-modifier-direction",
        str(direction),
        "--execution-providers",
        "cpu",
        "--log-level",
        "info",
    ]

    proc = subprocess.run(
        cmd,
        cwd=str(FF_ROOT),
        env=env,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not out.is_file():
        detail = (proc.stderr or proc.stdout or "FaceFusion de-age failed").strip()
        raise SystemExit(detail[-1500:])


if __name__ == "__main__":
    main()
