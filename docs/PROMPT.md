# 给 Claude Code 的 Prompt

所有长期规则都写在仓库根目录的 `AGENTS.md` 里，Claude Code 每次会话都会自动读取。下面这些是你在不同阶段要发给它的话，直接复制使用。

---

## 1. 第一次开工（新建会话时发送）

```
请先完整阅读仓库根目录的 AGENTS.md，它是这个项目的全部需求和规则。

然后按顺序做下面几件事：

1. 运行 `uname -s` 判断当前环境，并检查这些工具是否存在、版本是多少：
   swift、ffmpeg、ffprobe、exiftool、mkvpropedit、uchardet、iconv、ffmpeg-normalize、gh。
   缺少的工具，告诉我怎么装。如果找不到 swift，先试 `. ~/.local/share/swiftly/env.sh`。

2. 先不要写代码。给我一份简短的计划，包括：
   - Package.swift 的目标划分，以及 SkimCutApp 怎么只在 macOS 上加入；
   - M0 要建的文件列表；
   - ci.yml 的结构（linux 和 macos 两个 job、失败时把日志贴到 PR、上传 .app）；
   - 你对 AGENTS.md 有疑问或觉得有冲突的地方。

3. 我确认计划后，新建分支 `m0-skeleton` 完成 M0：
   - 在当前环境里跑通 `swift build` 和 `swift test`；
   - 推送并开 PR（云端用 REST 接口或内置 GitHub 工具，见 AGENTS.md 6.3），等 GitHub Actions 两个 job 的结果；
   - CI 失败就读日志并修复，直到全部通过。

4. 完成后告诉我：
   - 做了什么；
   - 在 Mac 上怎么拿到并打开 App（从 Actions 下载 artifact，或者本地运行 bundle-app.sh）；
   - 有哪些需要我在 Mac 上亲自检查。
```

---

## 2. 开始下一个里程碑（把 `M1` 换成对应编号）

```
M0 我已经在 Mac 上试过了，没问题，PR 已合并。
请按 AGENTS.md 开始 M1：
1. 先从 main 新建分支，列出 M1 的计划（要做什么、改哪些文件、怎么测试），等我确认；
2. 实现，并让 swift test 通过；
3. 开 PR，等 CI 全部通过；
4. 告诉我需要在 Mac 上检查的具体项目，以及每一项怎么检查。
```

---

## 3. CI 失败了

```
PR 上的 CI 失败了。请按 AGENTS.md 第 6.3 节的顺序，用 REST 接口查看失败日志
（check-runs 状态 → jobs/<id>/logs → PR 里自动贴的日志评论），
找出原因并修复，再推送，直到全部通过。
不要为了让 CI 通过而删除测试或跳过功能。
```

---

## 4. 我在 Mac 上试用后的反馈（按实际情况填写）

```
我在 Mac 上试用了 <里程碑编号>，结果如下：

正常的：
- ...

有问题的：
- 现象：...
- 操作步骤：...
- 期望的效果：...
- （如果有）错误提示 / 截图 / “复制完整命令和日志”的内容：...

请先分析可能的原因，告诉我你打算怎么改，再动手。
```

---

## 5. 检查需求有没有漏（建议每完成两三个里程碑做一次）

```
请逐条对照 AGENTS.md 第 4 节的功能需求，列一张表：
需求 | 状态（已完成 / 部分完成 / 未开始）| 在哪个文件实现 | 怎么测试的。
只列事实，不要修改代码。
```

---

## 6. 如果换到 Mac 本地运行 Claude Code

```
现在你运行在我的 Mac 上（请用 uname -s 确认）。
请运行 scripts/bundle-app.sh 打包，再用 open build/SkimCut.app 打开 App，
然后告诉我当前里程碑还有哪些需要我手动检查的地方。
```
