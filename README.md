# SkimCut

A lightweight native macOS video tool (Apple Silicon, macOS 14+).

- **Skimming preview** like Final Cut Pro: move the mouse over the timeline and the picture follows; rest to play from there.
- **Precise cut**: type a start and end time and save that part as a new file (fast lossless mode or frame-accurate mode).
- **Soft subtitles**: drop SRT / ASS / SSA / VTT files in and mux them as subtitle tracks (no burn-in).
- **Loudness fix**: measure loudness and write new files with even volume, softened bursts and smoother dynamics.
- **Video info and dates**: view metadata and add or change dates (inside the file and in Finder).

Heavy work is done by proven tools: FFmpeg, ffmpeg-normalize, ExifTool and MKVToolNix.

Status: planning. Project rules and requirements are in [`AGENTS.md`](AGENTS.md).
