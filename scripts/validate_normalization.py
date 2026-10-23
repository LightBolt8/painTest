#!/usr/bin/env python3
"""Check whether age normalization actually helps PSPI, using your own labeled photos.

Layout (either works):
  photos/neutral/*.jpg  photos/pain/*.jpg
  photos/*.jpg + labels.csv with columns: file,label[,subject]   (label = neutral | pain)

Usage:
  python3 scripts/validate_normalization.py photos/ [--labels labels.csv]
      [--bridge http://127.0.0.1:8765] [--target-age 25] [--out results.csv]

Every photo goes through the running bridge with age normalization on, which returns PSPI for
both the original and the normalized photo. The summary compares the two on:
  - separation: Cohen's d and AUC for pain vs neutral (higher is better)
  - age bias:   correlation between estimated age and PSPI on neutral photos (closer to 0 is better)
  - within-subject: mean pain - neutral difference when a subject has both (needs a subject column)
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import statistics
import sys
import urllib.request
from pathlib import Path

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}


def pspi_from_csv(text: str) -> tuple[float, float] | None:
    rows = list(csv.DictReader(io.StringIO(text), skipinitialspace=True))
    if not rows:
        return None
    row = rows[0]

    def value(key: str) -> float:
        try:
            return float(row.get(key) or 0)
        except ValueError:
            return 0.0

    # Same formula as the app's PSPI enum, using only OpenFace's AU outputs.
    def intensity(code: str) -> float:
        return min(max(value(f"{code}_r"), 0.0), 5.0)

    eyes_closed = value("AU45_c") >= 0.5 or value("AU45_r") >= 1.0
    pspi = (
        intensity("AU04")
        + max(intensity("AU06"), intensity("AU07"))
        + max(intensity("AU09"), intensity("AU10"))
        + (1.0 if eyes_closed else 0.0)
    )
    return pspi, value("confidence")


def collect(folder: Path, labels_path: Path | None) -> list[dict]:
    items = []
    if labels_path:
        with labels_path.open(newline="") as handle:
            for row in csv.DictReader(handle):
                items.append({
                    "path": folder / row["file"],
                    "label": row["label"].strip().lower(),
                    "subject": (row.get("subject") or "").strip(),
                })
    else:
        for label in ("neutral", "pain"):
            for path in sorted((folder / label).glob("*")):
                if path.suffix.lower() in IMAGE_SUFFIXES:
                    items.append({"path": path, "label": label, "subject": ""})
    return [item for item in items if item["label"] in ("neutral", "pain")]


def analyze(path: Path, bridge: str, target_age: int) -> dict:
    request = urllib.request.Request(
        bridge.rstrip("/") + "/analyze",
        data=path.read_bytes(),
        method="POST",
        headers={
            "Content-Type": "image/jpeg",
            "Accept": "application/json",
            "X-PainTest-Estimate-Age": "1",
            "X-PainTest-Deage": "1",
            "X-PainTest-Target-Age": str(target_age),
        },
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        data = json.loads(response.read())
    normalized = pspi_from_csv(data["csv"])
    original = pspi_from_csv(data["original_csv"]) if data.get("original_csv") else normalized
    age = data.get("age") or {}
    return {
        "age": age.get("age_estimate"),
        "deaged": data.get("deaged", False),
        "passes": data.get("passes", 0),
        "deaged_age": (data.get("deaged_age") or {}).get("age_estimate"),
        "drift": data.get("expression_drift"),
        "pspi_original": original[0] if original else None,
        "pspi_normalized": normalized[0] if normalized else None,
        "confidence": normalized[1] if normalized else None,
    }


def cohens_d(a: list[float], b: list[float]) -> float | None:
    if len(a) < 2 or len(b) < 2:
        return None
    pooled = (((len(a) - 1) * statistics.variance(a)) + ((len(b) - 1) * statistics.variance(b))) / (len(a) + len(b) - 2)
    return (statistics.mean(b) - statistics.mean(a)) / pooled ** 0.5 if pooled > 0 else None


def auc(neutral: list[float], pain: list[float]) -> float | None:
    if not neutral or not pain:
        return None
    wins = sum((p > n) + 0.5 * (p == n) for p in pain for n in neutral)
    return wins / (len(pain) * len(neutral))


def pearson(xs: list[float], ys: list[float]) -> float | None:
    if len(xs) < 3:
        return None
    try:
        return statistics.correlation(xs, ys)
    except statistics.StatisticsError:
        return None


def fmt(value: float | None, digits: int = 2) -> str:
    return "n/a" if value is None else f"{value:.{digits}f}"


def summarize(rows: list[dict]) -> None:
    ok = [r for r in rows if r.get("pspi_original") is not None and r.get("pspi_normalized") is not None]
    print(f"\n{len(ok)} of {len(rows)} photos analyzed; {sum(r['deaged'] for r in ok)} were de-aged.")
    drifts = [r["drift"] for r in ok if r.get("drift") is not None]
    if drifts:
        print(f"Expression drift from de-aging: mean {statistics.mean(drifts):.2f}, max {max(drifts):.2f} (0-5 scale)")

    print(f"\n{'':24}{'original':>10}{'normalized':>12}")
    for key_label, fn in (
        ("Cohen's d (pain>neutral)", lambda k: cohens_d(
            [r[k] for r in ok if r["label"] == "neutral"], [r[k] for r in ok if r["label"] == "pain"])),
        ("AUC", lambda k: auc(
            [r[k] for r in ok if r["label"] == "neutral"], [r[k] for r in ok if r["label"] == "pain"])),
        ("Age vs neutral PSPI r", lambda k: pearson(
            [r["age"] for r in ok if r["label"] == "neutral" and r["age"] is not None],
            [r[k] for r in ok if r["label"] == "neutral" and r["age"] is not None])),
    ):
        print(f"{key_label:24}{fmt(fn('pspi_original')):>10}{fmt(fn('pspi_normalized')):>12}")

    subjects: dict[str, dict[str, list[dict]]] = {}
    for r in ok:
        if r["subject"]:
            subjects.setdefault(r["subject"], {}).setdefault(r["label"], []).append(r)
    paired = {s: v for s, v in subjects.items() if "neutral" in v and "pain" in v}
    if paired:
        for key in ("pspi_original", "pspi_normalized"):
            diffs = [
                statistics.mean(x[key] for x in v["pain"]) - statistics.mean(x[key] for x in v["neutral"])
                for v in paired.values()
            ]
            print(f"Within-subject pain - neutral ({key.split('_')[1]}): mean {statistics.mean(diffs):.2f} over {len(diffs)} subjects")

    print(
        "\nNormalization is worth keeping only if separation is no worse and the age correlation shrinks toward 0."
        "\nIf not, rely on original-photo PSPI and each person's neutral-face baseline instead."
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--labels", type=Path)
    parser.add_argument("--bridge", default="http://127.0.0.1:8765")
    parser.add_argument("--target-age", type=int, default=25)
    parser.add_argument("--out", type=Path, default=Path("normalization_results.csv"))
    args = parser.parse_args()

    items = collect(args.folder, args.labels)
    if not items:
        raise SystemExit("No labeled photos found (expected neutral/ and pain/ folders or --labels).")

    rows = []
    for index, item in enumerate(items, 1):
        print(f"[{index}/{len(items)}] {item['path'].name} ({item['label']})", flush=True)
        row = {"file": item["path"].name, "label": item["label"], "subject": item["subject"]}
        try:
            row.update(analyze(item["path"], args.bridge, args.target_age))
        except Exception as exc:  # noqa: BLE001
            print(f"  failed: {exc}", file=sys.stderr)
        rows.append(row)

    fields = ["file", "label", "subject", "age", "deaged", "passes", "deaged_age", "drift",
              "pspi_original", "pspi_normalized", "confidence"]
    with args.out.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    print(f"Per-photo results: {args.out}")
    summarize(rows)


if __name__ == "__main__":
    main()
