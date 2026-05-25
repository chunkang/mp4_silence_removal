#!/usr/bin/env python3
"""Consolidate mp4s in the current directory, strip silence, keep ±3s around voice."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import venv
from pathlib import Path

VENV_DIR = Path.home() / ".cache" / "mp4_silence_removal" / "venv"
VENV_MARKER = "MP4SR_IN_VENV"
PIP_PACKAGES: list[str] = ["silero-vad", "numpy"]

PADDING_SECONDS = 3.0
VAD_THRESHOLD = 0.5
VAD_MIN_SPEECH_MS = 250
VAD_MIN_SILENCE_MS = 300

OUTPUT_PREFIX = "_mp4sr_"
CONSOLIDATED_NAME = f"{OUTPUT_PREFIX}consolidated.mp4"
FINAL_NAME = f"{OUTPUT_PREFIX}voice_only.mp4"


# ---------- bootstrap ----------

def _ensure_venv_and_reexec() -> None:
    if os.environ.get(VENV_MARKER) == "1":
        return
    if not VENV_DIR.exists():
        print(f"[mp4sr] creating venv at {VENV_DIR}")
        VENV_DIR.parent.mkdir(parents=True, exist_ok=True)
        venv.create(VENV_DIR, with_pip=True)
    venv_python = VENV_DIR / "bin" / "python3"
    if PIP_PACKAGES:
        pip = VENV_DIR / "bin" / "pip"
        missing = [p for p in PIP_PACKAGES if subprocess.run(
            [str(pip), "show", p], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        ).returncode != 0]
        if missing:
            print(f"[mp4sr] installing: {', '.join(missing)}")
            subprocess.check_call([str(pip), "install", "-q", *missing])
    env = {**os.environ, VENV_MARKER: "1"}
    os.execve(str(venv_python), [str(venv_python), os.path.abspath(__file__), *sys.argv[1:]], env)


def _ensure_ffmpeg() -> None:
    if shutil.which("ffmpeg") and shutil.which("ffprobe"):
        return
    if shutil.which("brew"):
        print("[mp4sr] installing ffmpeg via Homebrew")
        subprocess.check_call(["brew", "install", "ffmpeg"])
        return
    sys.exit("error: ffmpeg/ffprobe not found and Homebrew is unavailable; install ffmpeg manually")


# ---------- pipeline ----------

def find_mp4s(directory: Path) -> list[Path]:
    return sorted(
        p for p in directory.iterdir()
        if p.is_file()
        and p.suffix.lower() == ".mp4"
        and not p.name.startswith(OUTPUT_PREFIX)
    )


def consolidate(mp4s: list[Path], output: Path) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        for mp4 in mp4s:
            escaped = str(mp4.resolve()).replace("'", "'\\''")
            f.write(f"file '{escaped}'\n")
        list_file = f.name
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
             "-f", "concat", "-safe", "0", "-i", list_file,
             "-c", "copy", str(output)],
            check=True,
        )
    finally:
        os.unlink(list_file)


def probe_duration(mp4: Path) -> float:
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "json", str(mp4)]
    )
    return float(json.loads(out)["format"]["duration"])


def detect_voice(mp4: Path) -> list[tuple[float, float]]:
    """Use Silero VAD to find ranges containing human speech (in seconds)."""
    import numpy as np
    import torch
    from silero_vad import get_speech_timestamps, load_silero_vad

    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error",
         "-i", str(mp4), "-vn", "-ac", "1", "-ar", "16000",
         "-f", "s16le", "-acodec", "pcm_s16le", "-"],
        capture_output=True, check=True,
    )
    samples = np.frombuffer(proc.stdout, dtype=np.int16).astype(np.float32) / 32768.0
    wav = torch.from_numpy(samples)

    model = load_silero_vad()
    segments = get_speech_timestamps(
        wav, model,
        sampling_rate=16000,
        threshold=VAD_THRESHOLD,
        min_speech_duration_ms=VAD_MIN_SPEECH_MS,
        min_silence_duration_ms=VAD_MIN_SILENCE_MS,
        return_seconds=True,
    )
    return [(float(s["start"]), float(s["end"])) for s in segments]


def pad_and_merge(ranges: list[tuple[float, float]], pad: float, total: float) -> list[tuple[float, float]]:
    if not ranges:
        return []
    padded = sorted((max(0.0, s - pad), min(total, e + pad)) for s, e in ranges)
    merged = [padded[0]]
    for s, e in padded[1:]:
        ps, pe = merged[-1]
        if s <= pe:
            merged[-1] = (ps, max(pe, e))
        else:
            merged.append((s, e))
    return merged


def prompt_delete(originals: list[Path]) -> None:
    try:
        answer = input(f"delete {len(originals)} original mp4 file(s)? [y/N]: ")
    except EOFError:
        answer = ""
    if answer.strip().lower() != "y":
        print("[mp4sr] keeping originals")
        return
    for p in originals:
        try:
            p.unlink()
            print(f"[mp4sr] deleted {p.name}")
        except OSError as e:
            print(f"[mp4sr] failed to delete {p.name}: {e}")


def cut(source: Path, ranges: list[tuple[float, float]], output: Path) -> None:
    parts = []
    for i, (s, e) in enumerate(ranges):
        parts.append(f"[0:v]trim=start={s:.3f}:end={e:.3f},setpts=PTS-STARTPTS[v{i}];")
        parts.append(f"[0:a]atrim=start={s:.3f}:end={e:.3f},asetpts=PTS-STARTPTS[a{i}];")
    concat_in = "".join(f"[v{i}][a{i}]" for i in range(len(ranges)))
    filter_complex = "".join(parts) + f"{concat_in}concat=n={len(ranges)}:v=1:a=1[v][a]"
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
         "-i", str(source),
         "-filter_complex", filter_complex,
         "-map", "[v]", "-map", "[a]",
         str(output)],
        check=True,
    )


def main() -> None:
    cwd = Path.cwd()
    consolidated = cwd / CONSOLIDATED_NAME
    final = cwd / FINAL_NAME

    recreate = True
    if consolidated.exists():
        try:
            answer = input(f"{consolidated.name} exists. recreate? [y/N]: ")
        except EOFError:
            answer = ""
        recreate = answer.strip().lower() == "y"

    if recreate:
        mp4s = find_mp4s(cwd)
        if not mp4s:
            sys.exit(f"no .mp4 files found in {cwd}")
        print(f"[mp4sr] {len(mp4s)} input file(s), in order:")
        for p in mp4s:
            print(f"        {p.name}")
        print(f"[mp4sr] consolidating -> {consolidated.name}")
        consolidate(mp4s, consolidated)
        prompt_delete(mp4s)
    else:
        print(f"[mp4sr] reusing existing {consolidated.name}")

    total = probe_duration(consolidated)
    print(f"[mp4sr] duration: {total:.1f}s")

    print("[mp4sr] detecting voice (Silero VAD)")
    voice = pad_and_merge(detect_voice(consolidated), PADDING_SECONDS, total)
    if not voice:
        sys.exit("no voice detected; nothing to write")
    kept = sum(e - s for s, e in voice)
    print(f"[mp4sr] {len(voice)} voice range(s), keeping {kept:.1f}s ({kept / total * 100:.0f}%)")

    print(f"[mp4sr] writing -> {final.name}")
    cut(consolidated, voice, final)
    print(f"[mp4sr] done: {final}")


if __name__ == "__main__":
    _ensure_venv_and_reexec()
    _ensure_ffmpeg()
    main()
