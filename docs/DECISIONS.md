# 决定记录

AGENTS.md 没写到的小决定记在这里，附上原因。新的写在最上面。

## M2

- **快速模式的输出容器（用户确认）**：音视频编码 MP4 能装下（视频 H.264/HEVC/MPEG-4/AV1，音频 AAC/MP3/AC3/E-AC3/ALAC）就输出 `.mp4`，否则保持原来的容器（例如 Opus 音频的 MKV 输出 `.mkv`）。精确模式总是 `.mp4`。
- **精确模式的编码（用户确认）**：H.264 源 → `h264_videotoolbox`；HEVC 源 → `hevc_videotoolbox -tag:v hvc1`；其他编码：8-bit SDR → H.264，10-bit 或 HDR → HEVC main10（`-profile:v main10 -pix_fmt p010le`）。质量 `-q:v 65`，音频 AAC 192k。加 `-allow_sw 1`，没有硬件编码器的环境（CI 虚拟机）也能运行。
- **色彩参数**：精确模式沿用 ffprobe 读到的 `color_primaries` / `color_trc` / `colorspace` / `color_range`（未知的值不写）。
- **Dolby Vision**：ffprobe 的 side data 里有 DOVI 配置记录或编码标签是 dvh1/dvhe/dva1/dvav 时，精确模式导出前提示“Dolby Vision 元数据会丢失”。
- **快速模式的实际起点**：用 ffprobe 在起点前 15 秒、共 20 秒的范围里找关键帧（AGENTS.md 第 7 节），取不晚于起点的最后一个；找不到再从文件开头读到起点。关键帧时间要减去容器的 `start_time`，才和 `-ss` 对得上。已验证：`-ss 5 -t 2 -c copy` 在 4 秒一个关键帧的素材上输出从第 4.0 秒开始。
- **快速模式的终点**：复制模式按解码顺序截断，有 B 帧时终点会多带 1–3 帧（例如要求 7.0 秒，实际到 7.067 秒）。这是 `-c copy` 的固有行为，界面上只提示起点提前多少。
- **精确模式的 `-ss` 往前让 0.5 毫秒**：ffmpeg 精确 seek 会丢掉早于 `-ss` 的帧，而帧时间写成 6 位小数后可能比真实值大一点点（29.97 fps 等），会导致起点那一帧被丢掉。0.5 毫秒远小于半帧，不会多带前一帧。
- **精确到帧的验收测试**：有损编码的帧 MD5 不可能和源帧相同，所以测试用无损 libx264（`-qp 0`）/ libx265（`lossless=1`），用 `framemd5` 比对：第一帧正好是源文件起点那一帧，最后一帧和帧数也对。macOS 上另外用 VideoToolbox 导出，用 PSNR 找最像的源帧，必须是起点那一帧 ±1。
- **输出文件名**：`原名_cut_01m23.456s-01m35.456s.扩展名`；一小时以上写成 `1h02m03.456s`。重名时加 `_2`、`_3`……；ffmpeg 用 `-n`，万一文件已经存在也不会覆盖。
- **元数据**：源文件和输出都是 MP4/MOV 时，用 `exiftool -tagsFromFile 源 -all:all` 复制（已验证不会把时长改成源文件的时长）。录制时间平移的是**实际起点**（快速模式是关键帧位置），写入 `QuickTime:CreateDate`、`ModifyDate`、`Track*Date`、`Media*Date`（UTC）和 `Keys:CreationDate`（保留原来的时区）；源文件没有 Keys:CreationDate 时不添加。QuickTime 日期只到秒，平移后四舍五入。写完重新读取核对（容忍 1 秒），不一致就报错，并删除这个输出文件（元数据没写好的文件不算完成）。
- **输入框**：起点对齐到这个时间所在那一帧的开头；终点对齐到最近的帧边界（终点是区间的结尾，不包含终点那一帧）。“时长”模式下改起点时保持时长不变。在输入框里按回车后焦点回到播放画面，空格、J/K/L 等快捷键马上可以用。
- **导出前的提示**：选区或模式变化后停顿 0.35 秒才规划（快速模式要运行一次 ffprobe 找关键帧），媒体信息每个视频只读一次；空闲时不启动进程。
- **导出**：每个区间一个任务，进任务队列（一次一个），可以取消。⌘E 导出当前选区。导出记录显示在窗口底部，关闭视频后仍然保留，可以“清除已完成”。
- **设置**：新增“默认剪切模式”（默认精确）、“默认输出位置”（默认原文件旁边；设置的目录不存在时也回到原文件旁边）、“录制时间 = 原录制时间 + 剪切起点”（默认开）。
- **Trimlet**：只参考了它“快速 / 精确两种导出”的思路，没有复制代码，所以不需要附带它的许可证声明。

## M1

- **Skimming 与正常播放（用户确认）。** 用空格 / J / L 正常播放时，悬停只显示 skimmer 线，不打断播放（和 Final Cut Pro 一样）。停留后开始的播放属于 skimmer：不移动播放头，鼠标离开后画面回到播放头。点击或拖动时间轴才移动播放头。
- **正在 skimming 时按空格**：从 skimmer 位置开始播放，播放头移过去（Final Cut Pro 的行为）。
- **容差**：鼠标速度 ≥ 300 px/s 算快速移动，容差 ≈ 鼠标 100 ms 内划过的时长，限制在 0.1–2 秒；慢于这个速度用零容差。鼠标停下约 100 ms 后补一次零容差 seek（“停稳”）。速度做简单的指数平滑，停顿超过 0.2 秒重新计算。
- **计时**：“停稳”和“停留”都是鼠标移动后启动的一个一次性 `Task.sleep`，下一次移动取消它；没有循环计时器。播放时才注册 `addPeriodicTimeObserver`（1/30 秒），暂停就移除。
- **chase-time 状态机放在 SkimCore**（`ChaseSeeker`）：所有 seek（skimming、逐帧、点击、回到播放头）都经过它，同一时间最多一个 seek。
- **J/K/L**：L 1→2→4→8×，J −1→−2→−4→−8×，反方向时回到 1×，K 暂停。播放器不支持的速率（`canPlayReverse` 等）自动降级。
- **逐帧**：按帧网格（`minFrameDuration`，与 `nominalFrameRate` 一致时采用；NTSC 帧率用精确的 1001 分母）计算目标帧，再零容差 seek；seek 目标比帧开始晚 0.1 ms，避免浮点误差落到上一帧。
- **快捷键的实现**：空格、J/K/L、方向键由播放画面和时间轴（AppKit `NSView.keyDown`）处理，点击它们就获得焦点；不注册成菜单快捷键，以免以后（M2 的时间输入框）打字时被拦截。⌘+ / ⌘= / ⌘- 用菜单和 `performKeyEquivalent`。
- **时间轴颜色**：播放头黄色，skimmer 红色。
- **缩放范围**：最小是整段铺满；最大是一帧一张缩略图。触控板捏合以鼠标位置为中心，⌘+ / ⌘- 以播放头为中心（播放头不在可见范围时以中心）。滚轮和横向滑动滚动时间轴。
- **缩略图**：间隔按 2 的幂分级（`ThumbnailLadder`），同一级别的格子缩放时可以复用；格子比缩略图宽时重复画同一帧。只请求可见的格子，范围变化时取消旧请求。每个格子取**中间**那一帧（不取开头：很多视频第 0 秒是黑的，缩小时第一格会整格变黑——用户试用时发现），生成容差为格子间隔的四分之一（最多 2 秒），保证取到的帧在格子内。缓存上限 600 张 / 48 MB（LRU）。
- **预览方式**：先问 AVFoundation（`isPlayable` 且有视频轨道）；不行再用 ffprobe：H.264（8-bit 4:2:0）或 HEVC（8/10-bit 4:2:0）+ AAC（或无音频）→ `-c copy` 转封装（HEVC 加 `-tag:v hvc1`）；其他 → 代理。转封装后 AVPlayer 仍然打不开时自动改为代理。
- **代理参数**：高度 ≤ 540（不放大），GOP ≈ 0.5 秒（skimming 时 seek 快），8-bit 4:2:0 H.264 + AAC 立体声。macOS 用 `h264_videotoolbox -b:v 4M -allow_sw 1`（没有硬件编码器时允许系统软件编码器），Linux 测试用 `libx264 -preset veryfast -crf 26`。
- **预览临时文件**：`$TMPDIR/SkimCut-previews/session-<pid>-<随机>/`。关闭视频时删除对应文件，退出时删除会话目录，启动时删除进程已经不存在的旧目录。
- **测试素材**：新增 `sample_mpeg4.avi`（MPEG-4 Part 2 + MP2），用来测试“必须生成代理”的情况（用户确认）。HEVC 的 MKV 在测试里从 `hevc_10bit.mp4` 临时转出来，不加进素材脚本。
- **VideoToolbox 的测试**：只在 macOS 上运行；GitHub 的 macOS 虚拟机里编码器不可用时，只在 CI（有 `CI` 环境变量）上跳过。
- **CLI**：新增 `skimcut probe`（媒体信息和推测的预览方式）和 `skimcut preview`（生成预览文件，`--strategy auto|remux|proxy`，`--encoder`）。CLI 没有 AVFoundation，用 `PreviewPlanner.guessNativelyPlayable` 推测（MP4/MOV 里的 H.264/HEVC(hvc1) + 常见音频）。
- **关闭视频**：菜单“文件 > 关闭视频”（⇧⌘W）。⌘W 仍然是关闭窗口（会退出 App）。
- **时间轴两端留白 + 选区手柄（用户确认，提前到 M1）。** 时间轴左右各留 10 pt 空白，缩到最小时视频铺满中间的内容区；空白里鼠标对应开头 / 结尾，方便停到第一帧和最后一帧。选区默认是整段，两端是白色手柄（起点手柄在起点左侧、终点手柄在终点右侧，宽 7 pt）；拖动手柄改变起点 / 终点，吸附到最近的帧边界，画面显示选区里紧挨着手柄的那一帧；拖动开始时停止播放和 skimming 的定时器。区间外的缩略图变暗。
- **I / O**：I 把起点设在当前显示那一帧的开头，O 把终点设在当前显示那一帧的结尾（包含这一帧）；skimming 时“当前”是 skimmer 位置，否则是播放头。起点越过终点时终点回到结尾，反之起点回到开头（和 Final Cut Pro 一样）。选区的导出在 M2 做。

## M0

- **测试框架用 XCTest。** Linux 和 macOS 的 `swift test` 都稳定支持，不依赖 swift-testing 的版本差异。
- **Swift 6.1。** 云端手动安装 6.1.3，Linux CI 用 `swift:6.1-noble`；`swift-tools-version` 设为 6.0（Swift 6 语言模式，严格并发检查），macOS CI 用 macos-15 默认的 Xcode。
- **Bundle ID：`com.ddaxai.SkimCut`。** App 可执行文件名是 `SkimCutApp`（SwiftPM 的 target 名），显示名是 `SkimCut`。
- **任务队列默认一次只运行一个任务**（`TaskQueue(maxConcurrent: 1)`），保持轻量；以后需要并行（例如批量响度检测）再调整。
- **ToolLocator 的兜底 shell：macOS 用 `/bin/zsh -lc`，Linux 用 `/bin/sh -lc`。** 工具名作为位置参数 `$1` 传入，不拼接进脚本。只接受返回的绝对路径。
- **所有外部工具都设置 `LC_ALL`（macOS `en_US.UTF-8`，Linux `C.UTF-8`）。** 已验证：在 C locale 下 `mkvpropedit --set title=中文` 会写入空标题；从 Finder 启动的 App 没有 `LANG`，所以必须显式设置。
- **ToolRunner 的标准输入接 `/dev/null`。** ffmpeg 否则会读取终端输入。
- **取消任务会结束整棵进程树**（先 SIGTERM，2 秒后仍存活的 SIGKILL）。ffmpeg-normalize 会启动 ffmpeg 子进程，只结束父进程会留下孤儿进程。子进程查找：Linux 读 `/proc`，macOS 用 `/usr/bin/pgrep -P`（只在取消时调用）。
- **任务失败（非零退出）时也删除半成品输出**，和取消时一样。
- **stderr 只保留最后约 2 MB**，避免很长的 ffmpeg 日志占用内存；stdout 完整保留（ffprobe 的 JSON 需要完整）。
- **退出 App 时由 `ProcessRegistry.shared.terminateAll()` 同步结束所有子进程**，不经过任务队列 actor（`applicationWillTerminate` 是同步的）。
- **集成测试**：本地缺工具时跳过；CI 设置 `SKIMCUT_REQUIRE_TOOLS=1`，缺工具直接失败。测试素材由测试进程调用 `scripts/make-test-media.sh` 生成到临时目录。
- **测试素材** 额外的细节：10-bit HEVC 用 libx265 生成并带 `hvc1` 标签；字幕的 GBK 文件 uchardet 识别为 `GB18030`（GBK 的超集），后续按检测结果转换即可。
- **CI 的 linux job 失败时也把日志贴到 PR**（容器里没有 gh，用 `actions/github-script`），方便云端读取。
- **`skimcut --version`** 代替单独的 `version` 子命令（swift-argument-parser 自带）。
