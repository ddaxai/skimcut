# 决定记录

AGENTS.md 没写到的小决定记在这里，附上原因。新的写在最上面。

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
- **缩略图**：间隔按 2 的幂分级（`ThumbnailLadder`），同一级别的格子缩放时可以复用；格子比缩略图宽时重复画同一帧。只请求可见的格子，范围变化时取消旧请求。生成容差为格子间隔的一半（最多 2 秒）。缓存上限 600 张 / 48 MB（LRU）。
- **预览方式**：先问 AVFoundation（`isPlayable` 且有视频轨道）；不行再用 ffprobe：H.264（8-bit 4:2:0）或 HEVC（8/10-bit 4:2:0）+ AAC（或无音频）→ `-c copy` 转封装（HEVC 加 `-tag:v hvc1`）；其他 → 代理。转封装后 AVPlayer 仍然打不开时自动改为代理。
- **代理参数**：高度 ≤ 540（不放大），GOP ≈ 0.5 秒（skimming 时 seek 快），8-bit 4:2:0 H.264 + AAC 立体声。macOS 用 `h264_videotoolbox -b:v 4M -allow_sw 1`（没有硬件编码器时允许系统软件编码器），Linux 测试用 `libx264 -preset veryfast -crf 26`。
- **预览临时文件**：`$TMPDIR/SkimCut-previews/session-<pid>-<随机>/`。关闭视频时删除对应文件，退出时删除会话目录，启动时删除进程已经不存在的旧目录。
- **测试素材**：新增 `sample_mpeg4.avi`（MPEG-4 Part 2 + MP2），用来测试“必须生成代理”的情况（用户确认）。HEVC 的 MKV 在测试里从 `hevc_10bit.mp4` 临时转出来，不加进素材脚本。
- **VideoToolbox 的测试**：只在 macOS 上运行；GitHub 的 macOS 虚拟机里编码器不可用时，只在 CI（有 `CI` 环境变量）上跳过。
- **CLI**：新增 `skimcut probe`（媒体信息和推测的预览方式）和 `skimcut preview`（生成预览文件，`--strategy auto|remux|proxy`，`--encoder`）。CLI 没有 AVFoundation，用 `PreviewPlanner.guessNativelyPlayable` 推测（MP4/MOV 里的 H.264/HEVC(hvc1) + 常见音频）。
- **关闭视频**：菜单“文件 > 关闭视频”（⇧⌘W）。⌘W 仍然是关闭窗口（会退出 App）。

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
