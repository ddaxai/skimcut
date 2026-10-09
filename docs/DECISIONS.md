# 决定记录

AGENTS.md 没写到的小决定记在这里，附上原因。新的写在最上面。

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
