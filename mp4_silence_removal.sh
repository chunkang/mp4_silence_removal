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

# Quiet the "unauthenticated requests to the HF Hub / set a HF_TOKEN" advisory
# that silero-vad and faster-whisper emit while downloading models. Set before
# any huggingface_hub import so it takes effect. Downloads work fine without a token.
os.environ.setdefault("HF_HUB_VERBOSITY", "error")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

VENV_DIR = Path.home() / ".cache" / "mp4_silence_removal" / "venv"
VENV_MARKER = "MP4SR_IN_VENV"
PIP_PACKAGES: list[str] = ["silero-vad", "numpy", "faster-whisper"]

SETTINGS_FILE = Path.home() / ".config" / "mp4_silence_removal" / "settings.json"

PADDING_SECONDS = 5.0
VAD_THRESHOLD = 0.3
VAD_MIN_SPEECH_MS = 250
VAD_MIN_SILENCE_MS = 300
VOLUME_GAIN = 2.0
WHISPER_MODEL = "medium"

OUTPUT_PREFIX = "_mp4sr_"
CONSOLIDATED_NAME = f"{OUTPUT_PREFIX}consolidated.mp4"
FINAL_NAME = f"{OUTPUT_PREFIX}voice_only.mp4"
SUBTITLED_NAME = f"{OUTPUT_PREFIX}voice_only_subtitled.mp4"
VTT_NAME = f"{OUTPUT_PREFIX}voice_only.vtt"


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


# ---------- settings ----------

def load_settings() -> dict:
    try:
        return json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_settings(settings: dict) -> None:
    try:
        SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
        SETTINGS_FILE.write_text(json.dumps(settings, indent=2), encoding="utf-8")
    except OSError as e:
        print(f"[mp4sr] warning: could not save settings: {e}")


# ---------- pipeline ----------

def find_mp4s(directory: Path) -> list[Path]:
    return sorted(
        p for p in directory.iterdir()
        if p.is_file()
        and p.suffix.lower() == ".mp4"
        and not p.name.startswith(OUTPUT_PREFIX)
        and not p.name.startswith(".")
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


def detect_voice(mp4: Path, threshold: float) -> list[tuple[float, float]]:
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
        threshold=threshold,
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


class UndecodableInput(Exception):
    """Raised when a prompt receives a keystroke stdin can't decode."""


def safe_input(prompt: str) -> str:
    """input() that survives undecodable keystrokes.

    A stray IME / partial multibyte byte (e.g. 0xe3) makes the stdin reader
    raise UnicodeDecodeError. Re-raise it as UndecodableInput so callers can
    tell a garbled keystroke apart from a bare Enter: looping prompts re-prompt,
    one-shot prompts fall back to their default. EOFError still propagates.
    """
    try:
        return input(prompt)
    except UnicodeDecodeError:
        print()
        raise UndecodableInput


def prompt_threshold(default: float) -> float:
    print("[mp4sr] VAD threshold (0.0-1.0):")
    print("        0.7 -> only keep very confident speech (fewer false positives, may clip quiet talking)")
    print("        0.3 -> catch quieter / less clear speech (more false positives from background noise)")
    while True:
        try:
            answer = safe_input(f"threshold [{default}]: ")
        except UndecodableInput:
            continue
        except EOFError:
            return default
        answer = answer.strip()
        if not answer:
            return default
        try:
            value = float(answer)
        except ValueError:
            print(f"[mp4sr] invalid number: {answer!r}")
            continue
        if not 0.0 <= value <= 1.0:
            print("[mp4sr] threshold must be between 0.0 and 1.0")
            continue
        return value


def prompt_volume(default: float) -> float:
    while True:
        try:
            answer = safe_input(f"voice volume multiplier (1.0 = unchanged) [{default}]: ")
        except UndecodableInput:
            continue
        except EOFError:
            return default
        answer = answer.strip()
        if not answer:
            return default
        try:
            value = float(answer)
        except ValueError:
            print(f"[mp4sr] invalid number: {answer!r}")
            continue
        if value <= 0:
            print("[mp4sr] volume multiplier must be > 0")
            continue
        return value


def prompt_buffer(default: float) -> float:
    while True:
        try:
            answer = safe_input(f"buffer seconds before/after voice [{default}]: ")
        except UndecodableInput:
            continue
        except EOFError:
            return default
        answer = answer.strip()
        if not answer:
            return default
        try:
            value = float(answer)
        except ValueError:
            print(f"[mp4sr] invalid number: {answer!r}")
            continue
        if value < 0:
            print("[mp4sr] buffer must be >= 0")
            continue
        return value


def prompt_subtitles(default: bool) -> bool:
    hint = "Y/n" if default else "y/N"
    try:
        answer = safe_input(f"generate burned-in subtitles via Whisper? [{hint}]: ")
    except (UndecodableInput, EOFError):
        return default
    answer = answer.strip().lower()
    if not answer:
        return default
    return answer == "y"


def prompt_whisper_model(default: str) -> str:
    valid = {"tiny", "base", "small", "medium", "large-v3"}
    while True:
        try:
            answer = safe_input(f"whisper model (tiny/base/small/medium/large-v3) [{default}]: ")
        except UndecodableInput:
            continue
        except EOFError:
            return default
        answer = answer.strip()
        if not answer:
            return default
        if answer not in valid:
            print(f"[mp4sr] unknown model: {answer!r}")
            continue
        return answer


def prompt_delete(originals: list[Path]) -> None:
    try:
        answer = safe_input(f"delete {len(originals)} original mp4 file(s)? [y/N]: ")
    except (UndecodableInput, EOFError):
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


def transcribe(mp4: Path, model_size: str) -> list[tuple[float, float, str]]:
    """Run Whisper on the final mp4 and return [(start, end, text)] in seconds."""
    from faster_whisper import WhisperModel
    print(f"[mp4sr] loading whisper model: {model_size} (downloads on first use)")
    model = WhisperModel(model_size, device="cpu", compute_type="int8")
    print("[mp4sr] transcribing")
    # vad_filter=True: skip the padded near-silence around each voice range so
    #   Whisper does not hallucinate text there and its 30s decode window does
    #   not drift; faster-whisper maps the timestamps back to the real timeline.
    # word_timestamps=True: align segment start/end to actual word onsets (DTW)
    #   instead of coarse token-attention estimates.
    # condition_on_previous_text=False: stop one bad segment from cascading a
    #   timing/repetition error into everything after it.
    # These three together are what keep the .vtt in sync; see README.
    segments, _ = model.transcribe(
        str(mp4),
        vad_filter=True,
        word_timestamps=True,
        condition_on_previous_text=False,
    )
    out: list[tuple[float, float, str]] = []
    for seg in segments:
        text = seg.text.strip()
        if not text:
            continue
        # Prefer the first/last word's timing when available: it tracks the
        # spoken audio more tightly than the segment-level estimate.
        words = getattr(seg, "words", None) or []
        start = words[0].start if words else seg.start
        end = words[-1].end if words else seg.end
        out.append((float(start), float(end), text))
    return out


def _fmt_vtt_time(t: float) -> str:
    if t < 0:
        t = 0.0
    h = int(t // 3600)
    m = int((t % 3600) // 60)
    s = int(t % 60)
    ms = int(round((t - int(t)) * 1000))
    if ms == 1000:
        s += 1
        ms = 0
    return f"{h:02d}:{m:02d}:{s:02d}.{ms:03d}"


def write_vtt(segments: list[tuple[float, float, str]], path: Path) -> None:
    blocks: list[str] = ["WEBVTT\n"]
    for i, (start, end, text) in enumerate(segments, 1):
        blocks.append(f"{i}\n{_fmt_vtt_time(start)} --> {_fmt_vtt_time(end)}\n{text}\n")
    path.write_text("\n".join(blocks), encoding="utf-8")


def burn_subtitles(source: Path, vtt: Path, output: Path) -> None:
    # Run ffmpeg from the vtt's directory so we pass a bare filename and
    # avoid the subtitles filter's painful path escaping rules.
    #
    # force_style overrides the ASS style:
    #   BorderStyle=3            -> draw a box behind the text
    #   Outline=1                -> box padding around the text (px)
    #   Shadow=0                 -> no drop shadow
    #   OutlineColour=&H40000000 -> box colour in &HAABBGGRR (alpha 0x40 = mostly
    #                               opaque, pure black). Alpha is inverted in
    #                               ASS: 00 = opaque, FF = fully transparent.
    #   MarginL/MarginR=5        -> narrow horizontal margins.
    #   MarginV=40               -> lift subtitles ~40px up from the bottom.
    #   FontName=Apple SD Gothic Neo
    #                            -> one font covering BOTH Korean and Latin.
    #                               Without this, libass falls back to a
    #                               separate CJK font for Hangul runs, whose
    #                               ascent/descent differ from the Latin font,
    #                               so the BorderStyle=3 box is sized per-run
    #                               and its top/bottom edges step up and down
    #                               where the script changes. Pinning one font
    #                               keeps the box edges straight.
    style = "FontName=Apple SD Gothic Neo,Outline=1,Shadow=0,OutlineColour=&H80000000,MarginV=40,BorderStyle=3"
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-stats",
         "-i", str(source.resolve()),
         "-vf", f"subtitles={vtt.name}:force_style='{style}'",
         "-c:a", "copy",
         str(output.resolve())],
        check=True,
        cwd=str(vtt.parent),
    )


def cut(source: Path, ranges: list[tuple[float, float]], output: Path, volume_gain: float) -> None:
    parts = []
    for i, (s, e) in enumerate(ranges):
        parts.append(f"[0:v]trim=start={s:.3f}:end={e:.3f},setpts=PTS-STARTPTS[v{i}];")
        parts.append(f"[0:a]atrim=start={s:.3f}:end={e:.3f},asetpts=PTS-STARTPTS[a{i}];")
    concat_in = "".join(f"[v{i}][a{i}]" for i in range(len(ranges)))
    if volume_gain != 1.0:
        concat_tail = f"{concat_in}concat=n={len(ranges)}:v=1:a=1[v][araw];[araw]volume={volume_gain}[a]"
    else:
        concat_tail = f"{concat_in}concat=n={len(ranges)}:v=1:a=1[v][a]"
    filter_complex = "".join(parts) + concat_tail
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-stats",
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
    vtt_path = cwd / VTT_NAME

    settings = load_settings()

    make_final = True
    if final.exists():
        try:
            answer = safe_input(f"{final.name} exists. recreate? [y/N]: ")
        except EOFError:
            answer = ""
        make_final = answer.strip().lower() == "y"

    if make_final:
        recreate = True
        if consolidated.exists():
            try:
                answer = safe_input(f"{consolidated.name} exists. recreate? [y/N]: ")
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

        padding = prompt_buffer(settings.get("padding", PADDING_SECONDS))
        threshold = prompt_threshold(settings.get("threshold", VAD_THRESHOLD))
        volume_gain = prompt_volume(settings.get("volume_gain", VOLUME_GAIN))
        settings.update(padding=padding, threshold=threshold, volume_gain=volume_gain)
        save_settings(settings)

        print("[mp4sr] detecting voice (Silero VAD)")
        voice = pad_and_merge(detect_voice(consolidated, threshold), padding, total)
        if not voice:
            sys.exit("no voice detected; nothing to write")
        kept = sum(e - s for s, e in voice)
        print(f"[mp4sr] {len(voice)} voice range(s), keeping {kept:.1f}s ({kept / total * 100:.0f}%)")

        print(f"[mp4sr] writing -> {final.name}")
        cut(consolidated, voice, final, volume_gain)
        print(f"[mp4sr] done: {final}")
    else:
        print(f"[mp4sr] reusing existing {final.name}")

    want_subs = prompt_subtitles(settings.get("want_subs", False))
    settings["want_subs"] = want_subs
    if not want_subs:
        save_settings(settings)
        return

    # Only offer to reuse an existing .vtt when the video was NOT rebuilt this
    # run. If we just recut final with (possibly) different settings, the old
    # cue times are from the previous cut and would be desynced against it.
    reuse_vtt = False
    if vtt_path.exists() and not make_final:
        try:
            answer = safe_input(f"{vtt_path.name} exists. reuse it? [Y/n]: ")
        except EOFError:
            answer = ""
        reuse_vtt = answer.strip().lower() != "n"
    elif vtt_path.exists() and make_final:
        print(f"[mp4sr] {final.name} was rebuilt; regenerating {vtt_path.name} to keep it in sync")

    if reuse_vtt:
        print(f"[mp4sr] reusing existing {vtt_path.name}")
        save_settings(settings)
    else:
        whisper_model = prompt_whisper_model(settings.get("whisper_model", WHISPER_MODEL))
        settings["whisper_model"] = whisper_model
        save_settings(settings)
        segments = transcribe(final, whisper_model)
        if not segments:
            print("[mp4sr] no speech transcribed; skipping subtitle burn")
            return
        write_vtt(segments, vtt_path)
        print(f"[mp4sr] wrote {vtt_path.name} ({len(segments)} cue(s))")

    subtitled = cwd / SUBTITLED_NAME
    print(f"[mp4sr] burning subtitles -> {subtitled.name}")
    burn_subtitles(final, vtt_path, subtitled)
    print(f"[mp4sr] done: {subtitled}")


if __name__ == "__main__":
    _ensure_venv_and_reexec()
    _ensure_ffmpeg()
    main()
