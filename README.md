# mp4_silence_removal

Consolidate a folder of `.mp4` clips, strip out the silent gaps using voice
activity detection, and (optionally) burn in Whisper-generated subtitles.

## What it does

Run it from a directory full of `.mp4` files and it will, in order:

1. **Consolidate** every `.mp4` in the directory (sorted by name, dotfiles
   skipped) into a single `<prefix>consolidated.mp4`.
2. **Detect speech** with the Silero voice-activity detector, pad each voice
   range by a buffer, and merge overlapping ranges.
3. **Cut** the consolidated video down to just the voice ranges, writing
   `<prefix>voice_only.mp4`. Optionally boosts the voice volume.
4. **Subtitle** (optional): transcribe the trimmed audio with faster-whisper,
   write a WebVTT `.vtt`, and burn it into `<prefix>voice_only_subtitled.mp4`.

Each stage notices existing output and asks before recreating it, so you can
re-run to redo just the part you care about.

## Requirements

- Python 3
- `ffmpeg` / `ffprobe` (auto-installed via Homebrew if missing)

On first run the script creates its own virtualenv under
`~/.cache/mp4_silence_removal/venv`, installs its Python dependencies
(`silero-vad`, `numpy`, `faster-whisper`) into it, and re-execs itself — so you
don't need to install those by hand.

## Install

```sh
./_init.sh
```

This installs the script to `~/bin/mp4_silence_removal`. Make sure `~/bin` is on
your `PATH`, then run it from inside a folder of clips:

```sh
cd /path/to/clips
mp4_silence_removal
```

## Prompts and saved settings

You're prompted for a few values, each offered with the last value you used as
the default:

- **buffer seconds** — padding kept around each detected voice range (default 5)
- **VAD threshold** — how confident Silero must be to call audio "speech" (default 0.3)
- **voice volume multiplier** — gain applied to the kept audio (default 2.0; 1.0 = unchanged)
- **subtitles** — whether to transcribe and burn in subtitles
- **Whisper model** — `tiny`/`base`/`small`/`medium`/`large-v3` (default `medium`)

Your answers are saved to `~/.config/mp4_silence_removal/settings.json` and used
as the defaults next time.

## Subtitles: the box and mixed Korean/Latin text

Subtitles are burned with ffmpeg's `subtitles` (libass) filter as white text on
a semi-transparent black box lifted off the bottom edge. The box uses libass's
`BorderStyle=3`, which sizes the box from each glyph run's font metrics.

A single font, **Apple SD Gothic Neo**, is pinned for the whole subtitle via
`FontName`. This matters for lines that mix Korean and Latin: without a font
that covers both scripts, libass falls back to a separate CJK font for the
Hangul runs, and that font's different ascent/descent makes the box's top and
bottom edges step up and down where the script changes. Pinning one font that
has both scripts keeps the box edges straight.

The `force_style` overrides:

| Setting | Value | Effect |
| --- | --- | --- |
| `FontName` | `Apple SD Gothic Neo` | one font covering Korean + Latin, so the box edges stay straight |
| `BorderStyle` | `3` | opaque box behind the text |
| `Outline` | `1` | box padding around the glyphs |
| `Shadow` | `0` | no drop shadow |
| `OutlineColour` | `&H80000000` | 50%-opaque black box |
| `MarginV` | `40` | lift subtitles ~40px off the bottom |

The style lives in `burn_subtitles()` if you want to tweak it. To use a
different font, pick any with full Korean + Latin coverage (e.g. `NanumGothic`
or `Noto Sans CJK KR`).

### Keeping subtitles in sync

Cue timing comes entirely from Whisper, so the format (SRT vs WebVTT) makes no
difference to sync — the `.vtt` carries the same timestamps the burned-in
subtitles use. To keep those timestamps accurate, `transcribe()` runs Whisper
with VAD filtering, word-level timestamps, and `condition_on_previous_text=False`,
and takes each cue's start/end from its first and last word rather than the
coarser segment estimate.

Whisper's word-level alignment tends to stretch a cue's *first* word backward
into the pause before it, which makes the subtitle pop up a beat before the
speaker starts. `transcribe()` clamps that: when the first word "lasts" longer
than `SUBTITLE_LEAD_CAP_SECONDS` (0.7s), the excess is treated as absorbed
leading silence and the cue start is brought forward to the cap. Cues also never
start while the previous one is still on screen. Raise `SUBTITLE_LEAD_CAP_SECONDS`
if legitimately long opening words get clipped early.

If you rebuild `<prefix>voice_only.mp4`, the `.vtt` is regenerated automatically
(reusing an old subtitle file from a different cut would desync it) — you're only
offered to reuse an existing `.vtt` when the video was not rebuilt. If subtitles
still look off on a particular clip, try a larger Whisper model (e.g.
`large-v3`).

## Output files

- `<prefix>consolidated.mp4` — all inputs concatenated
- `<prefix>voice_only.mp4` — silence removed
- `<prefix>voice_only.vtt` — transcribed subtitles in WebVTT format (if enabled)
- `<prefix>voice_only_subtitled.mp4` — final, with subtitles burned in

(The `<prefix>` is `_mp4sr_`. When all inputs are consolidated, the script
offers to delete the originals.)
