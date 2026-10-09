# AGENTS.md — SkimCut（macOS 原生视频小工具）

本文件是项目的长期说明，每次会话开始时都要遵守。第 4 节的功能需求**全部必须实现，一条都不能少**。

## 1. 目标

项目所有者只用 Mac mini（Apple M4）和 macOS。要做一个**轻量**的原生 Mac App，在同一个窗口里完成：

1. Final Cut Pro 式的滑动预览（Skimming）
2. **（最重要）** 输入精确的时间段，把那一段剪出来，另存为一个**新文件**
3. 软字幕：把字幕文件封装进视频（不烧录到画面里）
4. 检测音量，并通过**修改文件**来统一音量、压低爆音、拉平忽大忽小的声音
5. 查看和修改视频信息，特别是**添加和修改日期**

“轻量”的意思：不在剪切、分析、导出的时候，App 几乎不占 CPU，内存也尽量小。

## 2. 先判断自己在哪个环境（每次会话开始时运行 `uname -s`）

- **Linux（Claude Code 云端，Ubuntu 24.04，没有 Xcode）**
  - 只编译和测试 `SkimCore` 与 `skimcut` CLI。集成测试要真正运行 ffmpeg、ffprobe、exiftool。
  - `SkimCutApp`（SwiftUI / AVFoundation）在 Linux 上**无法编译**。不要尝试编译它，也不要为了能在 Linux 上编译而删改它的代码。
  - App 代码只用确定存在的 API（部署目标 macOS 14）。改完后开 PR，由 GitHub Actions 的 macOS 任务编译和测试（见 6.3），**看到 CI 结果之后再继续下一步**。
  - 如果找不到 `swift` 命令，先运行 `. ~/.local/share/swiftly/env.sh`。
  - 云端会话里 **GitHub GraphQL 不可用**，所以 `gh pr create`、`gh pr checks`、`gh pr view`、`gh repo list` 等命令会失败。开 PR、查 CI 一律用内置的 GitHub 工具或 REST 接口（`gh api repos/ddaxai/skimcut/...`），见 6.3。
  - 云端网络只允许 HTTPS，代理会拒绝明文 HTTP（报 405）。依赖应该由云环境的 setup script 装好；缺工具时先告诉用户，**不要**关闭 TLS 校验或修改代理设置。
- **macOS**：所有部分都能编译、测试、打包、运行。用 `scripts/bundle-app.sh` 打包，用 `open build/SkimCut.app` 运行。

## 3. 技术栈与仓库结构（已定，不要更换）

- Swift 6，只用一个 SwiftPM Package（不用 `.xcodeproj`，不用 XcodeGen）。
- 界面用 SwiftUI，需要时用 AppKit（例如精细的鼠标追踪）。播放和解码用 AVFoundation。
- 重活全部通过 `Process` 调用命令行工具完成（见第 5 节）。
- **不要**改用 Rust、Tauri、Electron、Web 界面或 Python 图形界面。

```
Package.swift              # SkimCutApp 目标放在 #if os(macOS) 里，只在 macOS 上加入
Sources/SkimCore/          # 跨平台，只依赖 Foundation：工具查找、ToolRunner、剪切、字幕、音量、元数据、任务队列、时间解析
Sources/skimcut/           # 跨平台 CLI（swift-argument-parser），提供 Core 的全部功能，用于测试，也可以直接使用
Sources/SkimCutApp/        # 只在 macOS：SwiftUI 界面、AVPlayer、Skimmer、时间轴
Tests/SkimCoreTests/       # 单元测试 + 集成测试
Resources/Info.plist       # 打包 .app 用；声明支持的视频类型，这样才能把视频拖到 Dock 图标上打开
scripts/make-test-media.sh # 用 ffmpeg 生成测试素材
scripts/bundle-app.sh      # 仅 macOS：swift build -c release → build/SkimCut.app → ad-hoc 签名（codesign -s -）
.github/workflows/ci.yml
docs/DECISIONS.md          # 你做的决定和原因记在这里
```

- **业务逻辑全部放在 SkimCore，App 只负责界面和播放**，这样大部分代码可以在 Linux 上测试。
- 平台差异用 `#if os(macOS)` 隔离，例如 VideoToolbox 编码器、文件“创建日期”。
- 不要创建 `CLAUDE.md`。如果已经有，它只能包含一行 `@AGENTS.md`。

## 4. 功能需求（全部必须实现）

### 4.1 播放器与 Skimming
- 打开视频的方式：拖进窗口、菜单“打开”、拖到 Dock 图标上。
- 播放控制：空格播放/暂停、J/K/L、←/→ 逐帧、Shift+←/→ 跳 1 秒（秒数可以在设置里改）。
- 时间轴：缩略图条；支持缩放（触控板捏合、⌘+ / ⌘-）；显示当前时间 `HH:MM:SS.mmm`。
- **Skimming**：
  - 鼠标在时间轴上**悬停移动**时，主画面实时显示对应的那一帧，不需要点击。
  - 鼠标**停留**超过设定时间（默认 300 ms，可以在设置里改）后，**从这个位置开始播放**；再移动鼠标就回到 skimming。
  - 点击时间轴：移动播放头（playhead）。
  - 鼠标离开时间轴：画面回到播放头的位置。skimmer 和 playhead 是两个独立的位置。
  - 设置里可以关闭 skimming。
- Skimming 的实现方法：按 Apple QA1820 的 chase-time 写法——上一次 seek 完成之前不发新的 seek，只记住最新的目标时间。鼠标快速移动时用较宽的容差（tolerance），慢下来或停下时用零容差精确 seek。
- AVPlayer 打不开的格式（MKV、AVI、FLV、WMV 等）：
  - 如果编码是 H.264/HEVC + AAC，就用 `-c copy` 转封装成临时 MP4 来预览；
  - 否则用 VideoToolbox 生成低分辨率的预览代理文件。
  - 导出时永远使用**原始文件**作为输入。临时文件在关闭视频时删除。

### 4.2 精确剪切（最重要）
- 起点和终点输入框（也可以切换为“起点 + 时长”）。支持输入 `1:23.456`、`00:01:23.456`、`83.456`。
- 快捷键 `I` / `O` 把当前位置设为起点 / 终点，时间轴上高亮显示选中区间。
- 两种导出模式：
  - **快速（无损）**：`-c copy`。导出前用 ffprobe 算出实际起点，并告诉用户，例如“实际起点会提前 1.83 秒”。
  - **精确**：用 VideoToolbox 重新编码，起点和终点精确到帧。Linux 上的测试改用 libx264。
- 加分项：可以选择多个区间，每个区间分别导出。
- 输出文件名：`原名_cut_01m23.456s-01m35.456s.mp4`，放在原文件旁边（位置可以在设置里改）。

### 4.3 软字幕（只封装，不烧录）
- 支持拖入 SRT、ASS、SSA、VTT（必须支持）。SUP、IDX/SUB 这类图形字幕只能输出为 MKV。
- 可以添加多条字幕轨道，每条可设置语言（默认 `chi`）、标题、是否为默认轨道。
- 输出格式二选一：
  - **MP4**：文本字幕转成 `mov_text`。ASS 的样式会丢失，界面上要提示。
  - **MKV**：保留原格式和样式。
- 点“生成”按钮：视频和音频直接复制，不重新编码，生成 `原名_subs.mp4` / `.mkv`。
- 字幕编码：先用 `uchardet` 检测编码（中文字幕常见 GBK / GB18030 / Big5 / UTF-16），再用 `iconv` 转成 UTF-8 临时文件。
- 源视频里已有的字幕轨道默认保留，用户可以在列表里去掉。
- 如果同一次导出里也做了剪切，字幕时间要自动减去剪切起点。SRT/VTT 在 Swift 里平移时间，ASS 用 ffmpeg 处理。

### 4.4 音量：检测，并修改文件
用户的痛点：
- 有的视频声音很大，有的很小，播放器音量固定后每个视频都要重新调；
- 有的视频有爆破音（突然很响）；
- 有的人声或整体音量偏低，或者音量起伏太大。

**处理结果必须写进新文件**，这样换任何播放器都有效。
- **检测**：打开视频时在后台检测一次响度（设置里可以关掉），结果按“路径 + 大小 + 修改时间”缓存。显示整体响度 LUFS、真峰值 dBTP、响度范围 LRA。
- **批量列表**：可以一次拖入多个视频，列表显示每个视频的数值和处理状态，可以一键统一处理全部。这是解决“每个视频都要调一次”的关键。
- **爆音标记**：短时响度（每 100 ms 一个值）超过“整体响度 + X LU”（X 默认 10，可调）的位置，在时间轴上用红色标记；点击标记可以跳过去试听。
- **处理选项**（可以组合）：
  - 目标响度：默认 -16 LUFS，真峰值 -1.5 dBTP，都可调。
  - 强度预设：
    - **只统一音量**：线性增益，加 `--keep-loudness-range-target`；
    - **统一 + 拉平**：例如 `-lrt 7`；
    - **强力拉平**：前置 `acompressor`，再用更小的 `-lrt`。
  - 减少喷麦声：`highpass=f=80`，可以开关。
  - 局部压低爆音：对选中的标记或区间降低若干 dB（`volume=...:enable='between(t,a,b)'`）。表达式里的逗号要转义成 `\,`，必须用测试验证。
  - 削波修复：`adeclip` 作为可选项，并提示“只能改善，不能完全恢复”。
  - **试听对比**：从当前位置生成一段 15 秒的处理后预览，可以和原声一键切换。
- **写文件**：用 ffmpeg-normalize 处理。视频流直接复制，只重新编码音频。输出 `原名_norm.mp4`。已经接近目标的文件跳过（`--threshold 0.5`）。处理后重新检测，显示“处理前 → 处理后”的数值。

### 4.5 视频信息与日期
- **查看**：用 `exiftool -j -G1 -a -s -api QuickTimeUTC` 读取，分组显示（文件 / 视频 / 音频 / 日期 / 其他）。
- **修改和添加日期**（视频原来没有日期时也能添加）：
  - MP4/MOV 内部日期：`QuickTime:CreateDate`、`ModifyDate`、`Track*Date`、`Media*Date` 是 UTC；`Keys:CreationDate` 是本地时间，**必须带时区**，否则 Mac 的“照片” App 会显示错误日期。界面上让用户输入本地时间和时区，由程序换算后写入所有字段。
  - MKV 内部日期：用 `mkvpropedit`（ExifTool 不能写 MKV）。
  - 文件系统的“创建日期”和“修改日期”：用 `FileManager.setAttributes`（创建日期只在 macOS 上能改）。
  - 快捷操作：全部日期设为同一个时间；内部日期同步到文件日期；文件日期同步到内部日期。可以批量处理多个文件。
- 也可以编辑标题、描述/注释。
- 剪切、加字幕、改音量产生的新文件，自动从源文件复制元数据：`exiftool -tagsFromFile src -all:all`，只适用于 MP4/MOV。
- 可选（默认开启）：剪出的片段，录制时间 = 原录制时间 + 剪切起点。
- 写入后重新读取并验证，不一致就报错。

### 4.6 轻量与性能
- 暂停或空闲时：没有计时器、没有轮询、没有后台任务。目标 CPU < 1%。
- 只有在剪切、导出、分析、生成预览时才启动外部进程；任务结束后进程退出，临时文件删除。
- 缩略图只生成时间轴上可见的部分，结果缓存，并限制缓存大小。
- 所有耗时任务进入一个任务队列：
  - 显示进度（ffmpeg 加 `-progress pipe:1 -nostats`）；
  - 可以取消：结束子进程，并删除没完成的输出文件；
  - 退出 App 时结束所有子进程。
- 关闭视频时释放播放器、解码器和缓存。

### 4.7 通用
- 界面语言：中文。
- **永远不修改或删除原始视频**。只有用户选择“替换原文件”时，才把原文件移到废纸篓。修改日期会直接改原文件，所以执行前要弹窗确认。
- 输出文件重名时自动加序号，不覆盖已有文件。
- 外部工具出错时，用简单的中文说明错误，并提供“复制完整命令和日志”按钮。
- 设置项：默认输出位置、skimming 开关和停留时间、默认目标响度、默认剪切模式、默认字幕语言。

## 5. 必须复用的工具（不要用 Swift 重写这些功能）

| 用途 | 工具 |
|---|---|
| 剪切、转封装、字幕封装、响度分析 | ffmpeg |
| 流信息、关键帧（输出 JSON） | ffprobe |
| 统一响度（两遍 EBU R128，默认直接复制视频流） | ffmpeg-normalize |
| MP4/MOV 元数据 | exiftool |
| MKV 元数据 | mkvpropedit（MKVToolNix） |
| 字幕编码检测和转换 | uchardet、iconv |
| CLI 参数解析 | swift-argument-parser |
| 播放、硬件解码、缩略图 | AVFoundation（`AVPlayer`、`AVAssetImageGenerator`） |
| 快速/精确导出的规划逻辑 | 参考 github.com/jydie5/Trimlet（MIT 许可，可以借鉴代码，要保留许可证声明） |
| 无法播放的格式怎么预览 | 参考 LosslessCut 的思路（GPL 许可，**不要复制它的代码**） |

## 6. 命令

### 6.1 依赖
- Linux：`apt-get install -y ffmpeg libimage-exiftool-perl mkvtoolnix uchardet`；`uv tool install ffmpeg-normalize`。Swift 由云环境的 setup script 安装。
- macOS：`brew install ffmpeg exiftool mkvtoolnix uchardet uv`；`uv tool install ffmpeg-normalize`；需要安装 Xcode。

### 6.2 构建与测试
- `swift build`、`swift test`（两个平台都要能运行）
- macOS 打包：`scripts/bundle-app.sh` → `build/SkimCut.app`

### 6.3 CI（`.github/workflows/ci.yml`）
- **linux job**：用官方 `swift` Docker 镜像，安装 6.1 的依赖，运行 build + test。
- **macos job**：`runs-on: macos-15`（Apple Silicon）。
  - 运行 build + test + `bundle-app.sh`；
  - 用 `ditto -c -k --keepParent` 把 `SkimCut.app` 压成 zip，作为 artifact 上传；
  - 失败时用 `gh pr comment` 把构建/测试日志的最后约 150 行贴到 PR（需要 `pull-requests: write` 权限），这样云端的 Claude 也能读到错误。
  - 只在 `pull_request` 和 `workflow_dispatch` 时运行，节省 macOS 分钟数。
- 云端开 PR（REST）：`gh api repos/ddaxai/skimcut/pulls -f title="..." -f head=<分支> -f base=main -f body="..."`，或用内置的 GitHub 工具。
- 推送之后，按这个顺序查看 CI 结果（全部是 REST，云端可用）：
  1. 状态：`gh api repos/ddaxai/skimcut/commits/<commit sha>/check-runs --jq '.check_runs[] | {id,name,status,conclusion}'`
  2. 失败日志：`gh api repos/ddaxai/skimcut/actions/jobs/<上一步的 id>/logs`（Actions 的 check run id 就是 job id）
  3. 如果日志下载不了，读 CI 贴在 PR 里的日志评论：`gh api repos/ddaxai/skimcut/issues/<PR 编号>/comments`
- CI 还在运行时，隔一两分钟再查一次，不要连续快速轮询。

## 7. 关键技术细节（踩坑清单）

- **外部工具路径**：从 Finder 启动的 App 拿不到终端的 PATH。按这个顺序查找：`/opt/homebrew/bin`、`/usr/local/bin`、`/usr/bin`、`~/.local/bin`，最后用 `/bin/zsh -lc 'command -v X'` 兜底。调用 ffmpeg-normalize 时，用环境变量 `FFMPEG_PATH` 传入 ffmpeg 的完整路径。
- **参数一律用数组传给 `Process`，不要拼接 shell 字符串**，否则文件名里的空格和引号会出问题。参数生成单独写成函数，并写单元测试。
- **找关键帧**：`ffprobe -v error -select_streams v:0 -skip_frame nokey -read_intervals "{start-15}%+20" -show_entries frame=pts_time -of csv=p=0 in`
- **快速剪切**：`ffmpeg -ss S -i in -t D -map 0:v:0 -map 0:a? -c copy -avoid_negative_ts make_zero -movflags +faststart out`
- **精确剪切**：`-c:v hevc_videotoolbox -q:v 65 -tag:v hvc1 -c:a aac -b:a 192k`。源文件是 H.264 时改用 `h264_videotoolbox`。
  - HEVC 写进 MP4 **必须**加 `-tag:v hvc1`，否则 QuickTime 可能打不开。
  - 源文件是 10-bit 或 HDR（iPhone 视频常见）时，用 `-profile:v main10 -pix_fmt p010le`，并保留色彩参数。Dolby Vision 元数据保留不了时，在界面上提示。
- **只取视频和音频**：`-map 0:v:0 -map 0:a?`。iPhone 的 MOV 里有额外的数据轨道，不排除会导出失败。
- **字幕封装**：
  - MP4：`-map 0:v -map 0:a? -map 1 -c:v copy -c:a copy -c:s mov_text -metadata:s:s:0 language=chi -disposition:s:0 default`
  - MKV：`-c copy`
- **响度检测**：`ffmpeg -nostats -i in -map 0:a:0 -af loudnorm=print_format=json -f null -`，解析 stderr 末尾的 JSON（input_i、input_tp、input_lra）。
- **短时响度**：`-af "ebur128=metadata=1,ametadata=mode=print:key=lavfi.r128.M:file=OUT"`。已验证（ffmpeg 6.1）：输出文件每 0.1 秒两行，`frame:N    pts:P    pts_time:T` 后面跟一行 `lavfi.r128.M=-23.4`；开头约 0.4 秒窗口没填满时值约为 -120，解析时忽略。
- **ffmpeg-normalize**：`-nt ebu -t -16 -tp -1.5 -lrt 11 -prf "highpass=f=80" -c:a aac -b:a 192k -ar 48000 --threshold 0.5 -p -pr -o out`
  - `-ar 48000` 不能省：EBU 模式默认会把采样率改成 192 kHz。（已验证：ffmpeg 6.1 下不加 `-ar` 时，输出的采样率被改成了 96 kHz；加了以后是 48 kHz，并且视频流 MD5 与原文件完全相同。）
  - 局部压低的表达式里，逗号必须转义成 `\,`（已验证：不转义时 ffmpeg 报 `No such filter`）。
  - 默认目标是 -23 LUFS，默认输出扩展名是 mkv，所以 `-t` 和 `-o` 都要明确指定。
- **写日期**：`exiftool -api QuickTimeUTC -overwrite_original "-QuickTime:CreateDate=V" "-QuickTime:ModifyDate=V" "-Track*Date=V" "-Media*Date=V" "-Keys:CreationDate=V" file`，其中 V 形如 `2026:10:09 14:00:00+08:00`。
- **版本差异**：Linux 的 ffmpeg（apt 安装）通常比 macOS 的 brew 版本旧，不要使用只有最新版才有的参数。

## 8. 工作规则

- 开工前先给计划，等用户确认。每个里程碑：新建分支 → 实现 → 测试 → 开 PR → 等 CI 通过 → 告诉用户怎么在 Mac 上试用。
- 写 App 代码时同样要写测试：能放进 SkimCore 的逻辑都放进去测试。界面上的效果（skimming 是否顺畅、空闲时 CPU 占用）只能由用户在 Mac 上确认，要明确列出需要用户检查的地方。
- 本文件没写到、而且会明显影响结果的决定，先问用户；小决定自己做，并记到 `docs/DECISIONS.md`。
- 未经用户同意，不要增加本文件没有的大功能。

## 9. 里程碑（按顺序完成，每个完成后停下来等用户试用）

- **M0**：Package 骨架、ToolLocator、ToolRunner、任务队列、测试素材脚本、CI 两个 job 都能通过、`bundle-app.sh`、能打开的空窗口。
- **M1**：播放、缩略图时间轴、缩放、skimming、预览代理。验收：4K HEVC 视频快速划过时间轴时画面跟得上；暂停时 CPU < 1%（由用户验证）。
- **M2**：精确剪切全部功能（4.2），包括 HDR 处理和元数据复制。验收：精确模式导出的第一帧和指定时间的源帧一致（误差 ≤ 1 帧，用 `framemd5` 验证）。
- **M3**：软字幕全部功能（4.3）。
- **M4**：音量全部功能（4.4）。验收：3 个音量差异很大的测试视频处理后，都在目标值 ±1 LU 以内；视频流的 hash 和原文件一致（证明视频没有重新编码）。
- **M5**：信息与日期全部功能（4.5）。导入“照片” App 后日期是否正确，由用户验证。
- **M6**：可选的“一次导出”流水线（剪切 → 音量 → 字幕 → 元数据）、设置界面、错误提示、性能检查。

**测试素材**（`make-test-media.sh` 用 lavfi 生成）：
- 关键帧间隔 4 秒的 H.264 视频；
- 10-bit HEVC 视频；
- 3 个音量差异很大的视频；
- 一个中间带几段突然大声的视频；
- 一个 MKV；
- GBK 编码的 SRT，以及一个 ASS 字幕文件。
