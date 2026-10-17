# SkimCut

A lightweight native macOS video tool (Apple Silicon, macOS 14+).

- **Skimming preview** like Final Cut Pro: move the mouse over the timeline and the picture follows; rest to play from there.
- **Precise cut**: type a start and end time and save that part as a new file (fast lossless mode or frame-accurate mode).
- **Soft subtitles**: drop SRT / ASS / SSA / VTT files in and mux them as subtitle tracks (no burn-in).
- **Loudness fix**: measure loudness and write new files with even volume, softened bursts and smoother dynamics.
- **Video info and dates**: view metadata and add or change dates (inside the file and in Finder).

Heavy work is done by proven tools: FFmpeg, ffmpeg-normalize, ExifTool and MKVToolNix.

Status: M3 (soft subtitles). Project rules and requirements are in [`AGENTS.md`](AGENTS.md); small decisions are in [`docs/DECISIONS.md`](docs/DECISIONS.md).

## Build and run

Requirements (macOS): Xcode 16+, and `brew install ffmpeg exiftool mkvtoolnix uchardet uv && uv tool install ffmpeg-normalize`.

```sh
swift build && swift test           # works on macOS and Linux
swift run skimcut tools             # check external tools
swift run skimcut probe in.mkv      # stream info and the preview strategy
swift run skimcut preview in.avi    # remux or proxy file the app would play
swift run skimcut cut in.mp4 --start 1:23.456 --end 1:35.456 --mode precise
swift run skimcut keyframes in.mp4 --around 83.456
swift run skimcut subs in.mp4 --add a.srt:chi:中文 --add b.ass:eng --format mkv
scripts/make-test-media.sh          # generate test media into test-media/
scripts/bundle-app.sh               # macOS only → build/SkimCut.app
open build/SkimCut.app
```

### Using the app built by CI

Every pull request uploads `SkimCut-app` (a zip of `SkimCut.app`) as an artifact of the **macos** job.
The app is ad-hoc signed, so after downloading and unzipping run once:

```sh
xattr -dr com.apple.quarantine SkimCut.app
```

(or right-click → Open, then confirm in System Settings → Privacy & Security).
