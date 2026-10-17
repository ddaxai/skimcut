import Foundation
import XCTest
@testable import SkimCore

/// 真正运行 uchardet / iconv / ffmpeg / ffprobe 的字幕测试。
final class SubtitleIntegrationTests: XCTestCase {
    let runner = ToolRunner(registry: ProcessRegistry())

    private func probe(_ url: URL) async throws -> MediaInfo {
        try await MediaInfo.probe(url, runner: runner)
    }

    private func packetHashes(_ url: URL) async throws -> [String] {
        try await runner.output(try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-v", "error", "-i", url.path, "-map", "0:v:0", "-c", "copy", "-f", "framemd5", "-",
        ]))
        .split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }
        .compactMap { $0.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) }
    }

    /// 取出输出里第 `n` 条字幕，转成 `format`（srt / ass）文本。
    private func extractSubtitle(_ url: URL, _ n: Int, as format: String) async throws -> String {
        try await runner.output(try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-v", "error", "-i", url.path, "-map", "0:s:\(n)", "-f", format, "-",
        ]))
    }

    /// 输出里字幕流的语言、标题、默认标记和编码。
    private func subtitleStreams(_ url: URL) async throws -> [[String: String]] {
        let json = try await runner.run(try ToolLocator.shared.command(.ffprobe, [
            "-v", "error", "-select_streams", "s", "-show_entries",
            "stream=codec_name:stream_tags=language,title,handler_name:stream_disposition=default", "-of", "json", url.path,
        ])).stdout
        let root = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        return (root?["streams"] as? [[String: Any]] ?? []).map { s in
            let tags = s["tags"] as? [String: Any] ?? [:]
            let disposition = s["disposition"] as? [String: Any] ?? [:]
            var out: [String: String] = ["codec": s["codec_name"] as? String ?? ""]
            out["language"] = tags["language"] as? String
            out["title"] = (tags["title"] as? String) ?? (tags["handler_name"] as? String)
            out["default"] = "\((disposition["default"] as? NSNumber)?.intValue ?? 0)"
            return out
        }
    }

    private func externalTracks(_ media: URL) -> [SubtitleTrack] {
        [
            SubtitleTrack(source: .file(media.appendingPathComponent("subs_gbk.srt")), format: .srt, isDefault: true),
            SubtitleTrack(source: .file(media.appendingPathComponent("subs.ass")), format: .ass, language: "eng", title: "样式 字幕"),
        ]
    }

    func testGBKSubtitleIsDetectedAndConverted() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.uchardet)
        let srt = media.appendingPathComponent("subs_gbk.srt")
        let charset = try await SubtitleEncoding.detect(srt, runner: runner)
        XCTAssertFalse(SubtitleEncoding.isUTF8(charset))
        let text = try await SubtitleEncoding.readUTF8(srt, charset: charset, runner: runner)
        XCTAssertTrue(text.contains("你好，世界！这是第一条字幕。"))
        XCTAssertTrue(text.contains("GBK、GB18030、Big5"))
    }

    func testMP4ConvertsToMovTextWithLanguageTitleAndDefault() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.uchardet)
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("h264_gop4.mp4")
        let job = SubtitleJob(source: source, tracks: externalTracks(media), container: .mp4, outputDirectory: dir)
        let progress = LockedBox<[Double]>([])
        let result = try await SubtitleExporter(runner: runner).export(job, info: try await probe(source)) { p in
            if let p { progress.mutate { $0.append(p) } }
        }
        XCTAssertEqual(result.output.lastPathComponent, "h264_gop4_subs.mp4")
        XCTAssertEqual(progress.value.last, 1)
        XCTAssertEqual(result.warnings.count, 1, "ASS 样式会丢失的提示")

        let streams = try await subtitleStreams(result.output)
        XCTAssertEqual(streams.map { $0["codec"] }, ["mov_text", "mov_text"])
        XCTAssertEqual(streams.map { $0["language"] }, ["chi", "eng"])
        XCTAssertEqual(streams.map { $0["default"] }, ["1", "0"])
        XCTAssertEqual(streams[1]["title"], "样式 字幕")

        let srt = try await extractSubtitle(result.output, 0, as: "srt")
        XCTAssertTrue(srt.contains("你好，世界！这是第一条字幕。"), "GBK 转成了 UTF-8：\(srt.prefix(200))")
        XCTAssertTrue(srt.contains("00:00:01,000 --> 00:00:03,500"))

        // 视频没有重新编码；原文件不变。
        let src = try await packetHashes(source)
        let out = try await packetHashes(result.output)
        XCTAssertEqual(src, out)
        let original = try await probe(source)
        XCTAssertTrue(original.subtitleStreams.isEmpty)
    }

    func testMKVKeepsASSStyles() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.uchardet)
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("h264_gop4.mp4")
        let job = SubtitleJob(source: source, tracks: externalTracks(media), container: .mkv, outputDirectory: dir)
        let result = try await SubtitleExporter(runner: runner).export(job, info: try await probe(source))
        XCTAssertEqual(result.output.pathExtension, "mkv")
        XCTAssertTrue(result.warnings.isEmpty)
        let streams = try await subtitleStreams(result.output)
        XCTAssertEqual(streams.map { $0["codec"] }, ["subrip", "ass"])
        XCTAssertEqual(streams[1]["title"], "样式 字幕")
        let ass = try await extractSubtitle(result.output, 1, as: "ass")
        XCTAssertTrue(ass.contains("Style: Yellow,PingFang SC,40"), ass)
        XCTAssertTrue(ass.contains("{\\i1}带样式的{\\i0}第二条字幕"))
    }

    /// 源视频里已有的字幕轨道默认保留，也可以去掉。
    func testEmbeddedTracksKeptOrRemoved() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.uchardet)
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("with subs.mkv")
        _ = try await runner.run(try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-v", "error", "-i", media.appendingPathComponent("sample.mkv").path,
            "-sub_charenc", "GB18030", "-i", media.appendingPathComponent("subs_gbk.srt").path,
            // 字幕要重新编码成 UTF-8 的 SRT（-c copy 会把 GBK 的原始字节放进 MKV）。
            "-map", "0", "-map", "1", "-c:v", "copy", "-c:a", "copy", "-c:s", "srt",
            "-metadata:s:s:0", "language=jpn", "-metadata:s:s:0", "title=原有",
            source.path,
        ]))
        let info = try await probe(source)
        let embedded = info.subtitleStreams.compactMap(SubtitleTrack.embedded)
        XCTAssertEqual(embedded.count, 1)
        XCTAssertEqual(embedded.first?.language, "jpn")
        XCTAssertEqual(embedded.first?.title, "原有")

        let ass = SubtitleTrack(source: .file(media.appendingPathComponent("subs.ass")), format: .ass, isDefault: true)
        let kept = try await SubtitleExporter(runner: runner).export(
            SubtitleJob(source: source, tracks: embedded + [ass], container: .mp4, outputDirectory: dir), info: info)
        let keptStreams = try await subtitleStreams(kept.output)
        XCTAssertEqual(keptStreams.map { $0["language"] }, ["jpn", "chi"])
        XCTAssertEqual(keptStreams.map { $0["default"] }, ["0", "1"])

        let removed = try await SubtitleExporter(runner: runner).export(
            SubtitleJob(source: source, tracks: [ass], container: .mkv, outputDirectory: dir), info: info)
        let removedStreams = try await subtitleStreams(removed.output)
        XCTAssertEqual(removedStreams.map { $0["codec"] }, ["ass"])
    }

    /// 同时剪切：字幕时间按实际起点（关键帧 4 秒）平移，并对齐剪出来的第一帧视频；区间外的去掉，跨过终点的截断。
    func testCutWithSubtitlesShiftsByActualStart() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.uchardet)
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("h264_gop4.mp4")
        let job = SubtitleJob(
            source: source, tracks: externalTracks(media), container: .mkv,
            range: CutRange(start: 5, end: 9), outputDirectory: dir)
        let result = try await SubtitleExporter(runner: runner).export(job, info: try await probe(source))
        XCTAssertEqual(try XCTUnwrap(result.actualStart), 4, accuracy: 0.001)
        XCTAssertEqual(result.output.lastPathComponent, "h264_gop4_cut_00m05.000s-00m09.000s_subs.mkv")

        // 剪出来的第一帧视频在 v0 秒（有 B 帧时不是 0）：源 4.0 秒的字幕也要从 v0 开始。
        let out = try await probe(result.output)
        let v0 = try XCTUnwrap(out.videoStream?.startTime)
        func t(_ x: Double) -> String { SubtitleShifter.formatCueTime(x, .srt) }
        // SRT：1.0–3.5 在起点之前去掉；4.0–6.0 → v0…v0+2；7.25–9.75 → v0+3.25…v0+5（截到终点 9 秒）。
        let srt = try await extractSubtitle(result.output, 0, as: "srt")
        XCTAssertFalse(srt.contains("第一条字幕"))
        XCTAssertTrue(srt.contains("\(t(v0)) --> \(t(v0 + 2))"), srt)
        XCTAssertTrue(srt.contains("\(t(v0 + 3.25)) --> \(t(v0 + 5))"), srt)
        // ASS 也一样平移，样式保留。
        let ass = try await extractSubtitle(result.output, 1, as: "ass")
        XCTAssertTrue(ass.contains(",Yellow,"), ass)
        XCTAssertTrue(ass.contains("Style: Yellow"))

        // 视频从第 4 秒（第 120 帧）开始，没有重新编码。
        let src = try await packetHashes(source)
        let hashes = try await packetHashes(result.output)
        XCTAssertEqual(hashes, Array(src[120..<(120 + hashes.count)]))
        XCTAssertTrue((150...153).contains(hashes.count), "4.0–9.0 秒是 150 帧，复制模式终点可能多带几帧：\(hashes.count)")
        // 字幕不会把文件拉长（不会出现结尾定格）。
        XCTAssertLessThanOrEqual(try XCTUnwrap(out.duration), v0 + 5.2)
    }

    /// 剪切时原有字幕和新加字幕一样截到终点，文件不会因为字幕而变长。
    func testCutTrimsEmbeddedSubtitlesToo() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.uchardet)
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeSourceWithEmbeddedSubtitle(media, dir)
        let info = try await probe(source)
        let embedded = info.subtitleStreams.compactMap(SubtitleTrack.embedded)
        let external = SubtitleTrack(source: .file(media.appendingPathComponent("subs_gbk.srt")), format: .srt)
        // 新加的排在原有轨道前面：输出按列表顺序。
        let result = try await SubtitleExporter(runner: runner).export(
            SubtitleJob(source: source, tracks: [external] + embedded, container: .mkv,
                        range: CutRange(start: 5, end: 9), outputDirectory: dir), info: info)
        let out = try await probe(result.output)
        let streams = try await subtitleStreams(result.output)
        XCTAssertEqual(streams.map { $0["language"] }, ["chi", "jpn"])
        var lastEnds: [Double] = []
        for n in 0..<2 {
            let srt = try await extractSubtitle(result.output, n, as: "srt")
            let ends = srt.split(separator: "\n").filter { $0.contains("-->") }
                .compactMap { SubtitleShifter.parseCueTime(String($0.split(separator: " ").last ?? "")) }
            lastEnds.append(try XCTUnwrap(ends.max()))
        }
        // 两条字幕（原有的和新加的）都截在同一个终点（源文件 9 秒）。
        XCTAssertEqual(lastEnds[0], lastEnds[1], accuracy: 0.03, "\(lastEnds)")
        // 文件不会因为字幕而变长：时长不超过视频的最后一帧太多（原来会多出约 0.65 秒的定格）。
        let lastVideo = try await runner.output(try ToolLocator.shared.command(.ffprobe, [
            "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,duration_time",
            "-of", "csv=p=0", result.output.path,
        ])).split(whereSeparator: \.isNewline).compactMap { line -> Double? in
            let parts = line.split(separator: ",").compactMap { Double($0) }
            return parts.count == 2 ? parts[0] + parts[1] : nil
        }.max()
        XCTAssertLessThanOrEqual(try XCTUnwrap(out.duration), try XCTUnwrap(lastVideo) + 0.05, "字幕不能把文件拉长")
        XCTAssertLessThanOrEqual(lastEnds.max() ?? 0, try XCTUnwrap(lastVideo) + 0.05)
    }

    /// 源视频本来有字幕：去掉全部字幕，生成不带字幕的版本。
    func testRemovingAllSubtitles() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeSourceWithEmbeddedSubtitle(media, dir)
        let info = try await probe(source)
        let result = try await SubtitleExporter(runner: runner).export(
            SubtitleJob(source: source, tracks: [], container: .mp4, outputDirectory: dir), info: info)
        XCTAssertEqual(result.output.lastPathComponent, "with subs_nosubs.mp4")
        let out = try await probe(result.output)
        XCTAssertTrue(out.subtitleStreams.isEmpty)
        XCTAssertNotNil(out.videoStream)
        XCTAssertEqual(out.audioStreams.count, 1)
        // 源视频没有字幕时，空列表仍然报错。
        let plain = media.appendingPathComponent("h264_gop4.mp4")
        do {
            _ = try await SubtitleExporter(runner: runner).export(
                SubtitleJob(source: plain, tracks: [], container: .mp4, outputDirectory: dir), info: try await probe(plain))
            XCTFail("应该报“没有要写入的字幕轨道”")
        } catch let error as SubtitleError {
            XCTAssertEqual(error, .noTracks)
        }
    }

    /// 带一条原有字幕（日语 SRT，UTF-8）的 MKV。
    private func makeSourceWithEmbeddedSubtitle(_ media: URL, _ dir: URL) async throws -> URL {
        let source = dir.appendingPathComponent("with subs.mkv")
        _ = try await runner.run(try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-v", "error", "-i", media.appendingPathComponent("h264_gop4.mp4").path,
            "-sub_charenc", "GB18030", "-i", media.appendingPathComponent("subs_gbk.srt").path,
            // 字幕要重新编码成 UTF-8 的 SRT（-c copy 会把 GBK 的原始字节放进 MKV）。
            "-map", "0", "-map", "1", "-c:v", "copy", "-c:a", "copy", "-c:s", "srt",
            "-metadata:s:s:0", "language=jpn", "-metadata:s:s:0", "title=原有",
            source.path,
        ]))
        return source
    }

    func testOutputNeverOverwrites() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.uchardet)
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("h264_gop4.mp4")
        let existing = dir.appendingPathComponent("h264_gop4_subs.mp4")
        try Data("已有文件".utf8).write(to: existing)
        let job = SubtitleJob(source: source, tracks: [externalTracks(media)[0]], container: .mp4, outputDirectory: dir)
        let result = try await SubtitleExporter(runner: runner).export(job, info: try await probe(source))
        XCTAssertEqual(result.output.lastPathComponent, "h264_gop4_subs_2.mp4")
        XCTAssertEqual(try Data(contentsOf: existing), Data("已有文件".utf8))
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["h264_gop4_subs.mp4", "h264_gop4_subs_2.mp4"], "没有留下临时文件")
    }
}
