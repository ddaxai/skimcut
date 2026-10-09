#!/usr/bin/env bash
# 用 ffmpeg 的 lavfi 生成测试素材（AGENTS.md 第 9 节）。
# 用法：scripts/make-test-media.sh [输出目录]   默认输出到 test-media/
# 已经存在的文件会跳过；加 FORCE=1 重新生成。
set -euo pipefail

OUT="${1:-test-media}"
mkdir -p "$OUT"
FFMPEG="${FFMPEG:-ffmpeg}"
FF=("$FFMPEG" -hide_banner -loglevel error -nostdin -y)

need() {
  [[ "${FORCE:-0}" == 1 || ! -s "$OUT/$1" ]]
}

# 1. H.264 + AAC，20 秒，关键帧间隔正好 4 秒（30 fps × 120 帧）。
if need h264_gop4.mp4; then
  "${FF[@]}" -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=20" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=20" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 120 -keyint_min 120 -sc_threshold 0 \
    -c:a aac -b:a 128k -shortest -movflags +faststart "$OUT/h264_gop4.mp4"
fi

# 2. 10-bit HEVC（Main 10）+ AAC，6 秒，带 BT.709 色彩参数（容器和 HEVC 码流的 VUI 里都写）。
if need hevc_10bit.mp4; then
  "${FF[@]}" -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=6" \
    -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=6" \
    -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le \
    -x265-params log-level=error:colorprim=bt709:transfer=bt709:colormatrix=bt709 \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 -tag:v hvc1 \
    -c:a aac -b:a 128k -shortest "$OUT/hevc_10bit.mp4"
fi

# 3. 三个音量差异很大的视频（粉红噪声，振幅相差约 30 dB）。
make_level() {
  local name="$1" amp="$2"
  if need "$name"; then
    "${FF[@]}" -f lavfi -i "color=c=gray:size=640x360:rate=25:duration=10" \
      -f lavfi -i "anoisesrc=color=pink:amplitude=${amp}:sample_rate=48000:duration=10:seed=1" \
      -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -b:a 128k -shortest "$OUT/$name"
  fi
}
make_level loud_quiet.mp4 0.02
make_level loud_medium.mp4 0.1
make_level loud_loud.mp4 0.6

# 4. 中间带几段突然大声的视频：整体较轻，3.0–3.3 秒和 7.0–7.2 秒提高 24 dB。
if need bursts.mp4; then
  "${FF[@]}" -f lavfi -i "color=c=navy:size=640x360:rate=25:duration=10" \
    -f lavfi -i "anoisesrc=color=pink:amplitude=0.03:sample_rate=48000:duration=10:seed=2" \
    -af "volume=24dB:enable='between(t,3,3.3)',volume=24dB:enable='between(t,7,7.2)',alimiter=limit=0.99" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -b:a 128k -shortest "$OUT/bursts.mp4"
fi

# 5. MKV（H.264 + AAC，可以直接转封装成 MP4 预览）。
if need sample.mkv; then
  "${FF[@]}" -f lavfi -i "testsrc2=size=640x360:rate=25:duration=8" \
    -f lavfi -i "sine=frequency=330:sample_rate=48000:duration=8" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 50 -c:a aac -b:a 128k -shortest "$OUT/sample.mkv"
fi

# 6. AVPlayer 打不开、也不能直接转封装的 AVI（MPEG-4 Part 2 + MP2），用来测试预览代理。
if need sample_mpeg4.avi; then
  "${FF[@]}" -f lavfi -i "testsrc2=size=640x360:rate=25:duration=6" \
    -f lavfi -i "sine=frequency=550:sample_rate=48000:duration=6" \
    -c:v mpeg4 -q:v 5 -pix_fmt yuv420p -c:a mp2 -b:a 128k -shortest "$OUT/sample_mpeg4.avi"
fi

# 7. 字幕：GBK 编码的 SRT，以及一个带样式的 ASS。
if need subs_gbk.srt; then
  tmp="$(mktemp)"
  cat > "$tmp" <<'SRT'
1
00:00:01,000 --> 00:00:03,500
你好，世界！这是第一条字幕。

2
00:00:04,000 --> 00:00:06,000
中文字幕常见编码：GBK、GB18030、Big5。

3
00:00:07,250 --> 00:00:09,750
第三条字幕，测试时间平移。
SRT
  iconv -f UTF-8 -t GBK "$tmp" > "$OUT/subs_gbk.srt"
  rm -f "$tmp"
fi

if need subs.ass; then
  cat > "$OUT/subs.ass" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,PingFang SC,48,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,40,1
Style: Yellow,PingFang SC,40,&H0000FFFF,&H000000FF,&H00000000,&H64000000,1,0,0,0,100,100,0,0,1,2,1,8,20,20,40,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,第一条 ASS 字幕
Dialogue: 0,0:00:04.00,0:00:06.00,Yellow,,0,0,0,,{\i1}带样式的{\i0}第二条字幕
Dialogue: 0,0:00:07.25,0:00:09.75,Default,,0,0,0,,第三条字幕
ASS
fi

echo "测试素材已生成在 $OUT/"
ls -l "$OUT"
