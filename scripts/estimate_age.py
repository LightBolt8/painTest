#!/usr/bin/env python3
"""Estimate apparent age of the largest face in an image with FaceFusion's fairface classifier.

Usage:
  python3 scripts/estimate_age.py input.jpg

Prints JSON:
  {"age_low": 30, "age_high": 39, "age_estimate": 36.2, "age_std": 4.1, "fran_source_age": 34.0}

- age_low / age_high: the most likely fairface band (inclusive).
- age_estimate: expected age over all nine bands' probabilities, averaged with the mirrored face,
  so it moves smoothly within and across bands instead of jumping by a decade.
- age_std: spread of that distribution, a rough ± for the estimate.
- fran_source_age: the band midpoint FaceFusion's FRAN age modifier assumes as the starting age,
  so target-age de-aging should use direction = target_age - fran_source_age.

Re-runs itself under the `facefusion` conda env when FaceFusion's dependencies are missing.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FF_ROOT = ROOT / "FaceFusion"
FAIRFACE = FF_ROOT / ".assets" / "models" / "fairface.onnx"
FAIRFACE_LOGITS = FF_ROOT / ".assets" / "models" / "fairface_age_logits.onnx"
# The graph slices its fc output into race / gender / age logits and argmaxes each;
# this is the age slice before the argmax.
AGE_LOGITS_TENSOR = "/Slice_2_output_0"
# Representative ages for fairface's bands 0-2, 3-9, 10-19, ..., 60-69, 70+.
BAND_AGES = [1.0, 6.0, 14.5, 24.5, 34.5, 44.5, 54.5, 64.5, 77.0]


def reexec_in_facefusion_env() -> None:
    sys.path.insert(0, str(ROOT / "scripts"))
    from deage_face import resolve_python  # noqa: PLC0415

    python = resolve_python()
    if Path(python).resolve() == Path(sys.executable).resolve():
        raise SystemExit("FaceFusion environment not found (conda env `facefusion`).")
    env = os.environ.copy()
    env["KMP_DUPLICATE_LIB_OK"] = "TRUE"
    env["OMP_NUM_THREADS"] = "1"
    os.execve(python, [python, __file__, *sys.argv[1:]], env)


def age_logits_session():
    import onnx  # noqa: PLC0415
    import onnxruntime  # noqa: PLC0415

    if not FAIRFACE_LOGITS.is_file() or FAIRFACE_LOGITS.stat().st_mtime < FAIRFACE.stat().st_mtime:
        model = onnx.load(str(FAIRFACE))
        model.graph.output.append(onnx.helper.make_tensor_value_info(AGE_LOGITS_TENSOR, onnx.TensorProto.FLOAT, None))
        onnx.save(model, str(FAIRFACE_LOGITS))
    return onnxruntime.InferenceSession(str(FAIRFACE_LOGITS), providers=["CPUExecutionProvider"])


def age_distribution(frame, face) -> list[float]:
    """Band probabilities for the face, averaged over the image and its mirror."""
    import numpy  # noqa: PLC0415
    from facefusion.face_classifier import get_model_options  # noqa: PLC0415
    from facefusion.face_helper import warp_face_by_face_landmark_5  # noqa: PLC0415

    options = get_model_options()
    crop, _ = warp_face_by_face_landmark_5(
        frame, face.landmark_set.get("5/68"), options.get("template"), options.get("size")
    )
    crop = crop.astype(numpy.float32)[:, :, ::-1] / 255.0
    crop = (crop - options.get("mean")) / options.get("standard_deviation")
    batch = numpy.stack([crop, crop[:, ::-1, :]]).transpose(0, 3, 1, 2).astype(numpy.float32)

    session = age_logits_session()
    probs = []
    for sample in batch:
        outputs = session.run([AGE_LOGITS_TENSOR], {"input": sample[None]})
        logits = numpy.asarray(outputs[0]).reshape(-1)
        exp = numpy.exp(logits - logits.max())
        probs.append(exp / exp.sum())
    return [float(p) for p in numpy.mean(probs, axis=0)]


def estimate(image_path: str) -> dict:
    sys.path.insert(0, str(FF_ROOT))
    os.chdir(FF_ROOT)

    from facefusion import state_manager  # noqa: PLC0415
    from facefusion.args import apply_args  # noqa: PLC0415
    from facefusion.face_creator import get_many_faces  # noqa: PLC0415
    from facefusion.program import create_program  # noqa: PLC0415
    from facefusion.vision import read_static_image  # noqa: PLC0415

    program = create_program()
    args = vars(program.parse_args([
        "headless-run",
        "--target-path", image_path,
        "--output-path", os.devnull,
        "--execution-providers", "cpu",
        "--log-level", "error",
    ]))
    apply_args(args, state_manager.init_item)

    frame = read_static_image(image_path)
    if frame is None:
        raise RuntimeError("Could not read image")
    faces = get_many_faces([frame])
    if not faces:
        raise RuntimeError("No face found for age estimate")

    def area(face) -> float:
        x1, y1, x2, y2 = face.bounding_box
        return float((x2 - x1) * (y2 - y1))

    face = max(faces, key=area)
    band = face.age
    result = {
        "age_low": int(band.start),
        "age_high": int(band.stop),
        "fran_source_age": round(sum(band) / len(band), 1),
    }
    try:
        probs = age_distribution(frame, face)
        mean = sum(p * a for p, a in zip(probs, BAND_AGES))
        var = sum(p * (a - mean) ** 2 for p, a in zip(probs, BAND_AGES))
        result["age_estimate"] = round(mean, 1)
        result["age_std"] = round(var ** 0.5, 1)
    except Exception:  # noqa: BLE001
        result["age_estimate"] = result["fran_source_age"]
    return result


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: estimate_age.py input.jpg")
    image_path = str(Path(sys.argv[1]).resolve())
    try:
        import onnxruntime  # noqa: F401, PLC0415
        import cv2  # noqa: F401, PLC0415
    except ImportError:
        reexec_in_facefusion_env()

    import contextlib  # noqa: PLC0415
    import io  # noqa: PLC0415

    noise = io.StringIO()
    try:
        with contextlib.redirect_stdout(noise):
            result = estimate(image_path)
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"error": str(exc)}))
        sys.exit(1)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
