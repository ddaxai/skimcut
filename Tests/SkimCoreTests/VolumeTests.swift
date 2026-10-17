import Foundation
import XCTest
@testable import SkimCore

/// 音量：参数生成、滤镜转义、输出解析、爆音检测、缓存（不运行外部工具）。
final class VolumeTests: XCTestCase {
    let input = URL(fileURLWithPath: "/v/my clip.mp4")
    let output = URL(fileURLWithPath: "/v/.my clip_norm.skimcut-1.mp4")

    // MARK: - 滤镜

    func testDuckFilterEscapesCommas() {
        let duck = VolumeDuck(start: 3, end: 3.3, gain: -12)
        XCTAssertEqual(NormalizePlanner.duckFilter(duck), #"volume=-12.0dB:enable='between(t\,3.000\,3.300)'"#)
    }

    func testDuckFilterShiftAndLimit() {
        let duck = VolumeDuck(start: 10, end: 10.3, gain: -9)
        XCTAssertEqual(NormalizePlanner.duckFilter(duck, shift: 8, limit: 15), #"volume=-9.0dB:enable='between(t\,2.000\,2.300)'"#)
        // 跨过片段开头：从 0 开始。
        XCTAssertEqual(NormalizePlanner.duckFilter(duck, shift: 10.1, limit: 15), #"volume=-9.0dB:enable='between(t\,0.000\,0.200)'"#)
        XCTAssertNil(NormalizePlanner.duckFilter(duck, shift: 11, limit: 15), "在片段之前")
        XCTAssertNil(NormalizePlanner.duckFilter(duck, shift: 0, limit: 5), "在片段之后")
    }

    func testPreFilterOrder() {
        XCTAssertNil(NormalizePlanner.preFilters(NormalizeOptions(), stats: nil))
        let options = NormalizeOptions(
            preset: .strong, highpass: true, declip: true, ducks: [VolumeDuck(start: 1, end: 2, gain: -6)])
        let stats = LoudnessStats(integrated: -30, truePeak: -10, range: 8)
        let chain = NormalizePlanner.preFilters(options, stats: stats)!
        XCTAssertEqual(chain, "adeclip,highpass=f=80,volume=14.00dB,acompressor=threshold=0.07943:ratio=3:attack=10:release=250")
        // 局部压低在 loudnorm 后面。
        XCTAssertEqual(NormalizePlanner.postFilters(options), #"volume=-6.0dB:enable='between(t\,1.000\,2.000)'"#)
        XCTAssertNil(NormalizePlanner.postFilters(NormalizeOptions()))
        let args = NormalizePlanner.arguments(input: input, output: output, options: options, stats: stats)
        XCTAssertEqual(args[args.firstIndex(of: "-pof")! + 1], #"volume=-6.0dB:enable='between(t\,1.000\,2.000)'"#)
    }

    func testCompressorWithoutStatsHasNoGain() {
        XCTAssertEqual(NormalizePlanner.compressorFilters(target: -16, stats: nil),
                       ["acompressor=threshold=0.07943:ratio=3:attack=10:release=250"])
        // 已经在目标附近：不加增益。
        let near = LoudnessStats(integrated: -16.02, truePeak: -3, range: 5)
        XCTAssertEqual(NormalizePlanner.compressorFilters(target: -16, stats: near).count, 1)
    }

    // MARK: - ffmpeg-normalize 参数

    func testUnifyArguments() {
        let args = NormalizePlanner.arguments(input: input, output: output, options: NormalizeOptions(), stats: nil)
        XCTAssertEqual(args, [
            "/v/my clip.mp4", "-nt", "ebu", "-t", "-16", "-tp", "-1.5", "--keep-loudness-range-target",
            "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "--threshold", "0.5", "-p", "-pr", "-o", output.path,
        ])
    }

    func testFlattenAndRepairArguments() {
        let options = NormalizeOptions(targetLoudness: -14, truePeak: -1, preset: .flatten, highpass: true)
        let args = NormalizePlanner.arguments(input: input, output: output, options: options, stats: nil)
        XCTAssertEqual(args, [
            "/v/my clip.mp4", "-nt", "ebu", "-t", "-14", "-tp", "-1", "-lrt", "7",
            "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-prf", "highpass=f=80", "-p", "-pr", "-o", output.path,
        ])
        XCTAssertFalse(args.contains("--threshold"), "选了修复或拉平时不交给 ffmpeg-normalize 跳过")
        let strong = NormalizePlanner.arguments(
            input: input, output: output, options: NormalizeOptions(preset: .strong), stats: nil)
        XCTAssertEqual(strong[strong.firstIndex(of: "-lrt")! + 1], "5")
        XCTAssertTrue(strong[strong.firstIndex(of: "-prf")! + 1].hasPrefix("acompressor="))
    }

    func testShouldSkip() {
        let near = LoudnessStats(integrated: -16.3, truePeak: -2, range: 9)
        XCTAssertTrue(NormalizePlanner.shouldSkip(near, options: NormalizeOptions()))
        XCTAssertFalse(NormalizePlanner.shouldSkip(near, options: NormalizeOptions(preset: .flatten)), "范围 9 LU > 7")
        XCTAssertFalse(NormalizePlanner.shouldSkip(near, options: NormalizeOptions(highpass: true)))
        XCTAssertFalse(NormalizePlanner.shouldSkip(near, options: NormalizeOptions(ducks: [VolumeDuck(start: 0, end: 1, gain: -6)])))
        XCTAssertFalse(NormalizePlanner.shouldSkip(LoudnessStats(integrated: -16.6, truePeak: -2, range: 3), options: NormalizeOptions()))
        XCTAssertFalse(NormalizePlanner.shouldSkip(LoudnessStats(integrated: -16, truePeak: 0, range: 3), options: NormalizeOptions()),
                       "真峰值超标")
        XCTAssertTrue(NormalizePlanner.shouldSkip(LoudnessStats(integrated: -16, truePeak: -2, range: 6), options: NormalizeOptions(preset: .flatten)))
    }

    func testOutputNames() {
        XCTAssertEqual(NormalizePlanner.outputFileName(source: URL(fileURLWithPath: "/a/片段.MOV")), "片段_norm.mov")
        XCTAssertEqual(NormalizePlanner.outputFileName(source: URL(fileURLWithPath: "/a/x.mkv")), "x_norm.mkv")
        XCTAssertEqual(NormalizePlanner.outputFileName(source: URL(fileURLWithPath: "/a/x.avi")), "x_norm.mkv")
        XCTAssertEqual(NormalizePlanner.outputFileName(source: URL(fileURLWithPath: "/a/x.webm")), "x_norm.mkv")
    }

    // MARK: - ffmpeg-normalize 输出

    func testParseProgress() {
        XCTAssertEqual(NormalizePlanner.parseProgress("Stream 1/2: 45.20% |████▌     | 45.2/100 [00:00<00:01, 23.39it/s]\u{1B}[A"),
                       .firstPass(stream: 1, of: 2, percent: 45.2))
        XCTAssertEqual(NormalizePlanner.parseProgress("Second Pass: 100.00% |██████████| 100.0/100 [00:02<00:00]"),
                       .secondPass(percent: 100))
        XCTAssertEqual(NormalizePlanner.parseProgress("\u{1B}[ASecond Pass: 10.48% |█         |"), .secondPass(percent: 10.48))
        XCTAssertNil(NormalizePlanner.parseProgress("File:   0%|          | 0/1 [00:00<?, ?it/s]"))
        XCTAssertNil(NormalizePlanner.parseProgress("WARNING: something"))

        XCTAssertEqual(NormalizeProgress.firstPass(stream: 1, of: 1, percent: 50).fraction, 0.25, accuracy: 1e-9)
        XCTAssertEqual(NormalizeProgress.firstPass(stream: 2, of: 2, percent: 0).fraction, 0.25, accuracy: 1e-9)
        XCTAssertEqual(NormalizeProgress.secondPass(percent: 50).fraction, 0.75, accuracy: 1e-9)
    }

    func testParseReport() {
        let normalized = #"""
        [{"input_file": "a.mp4", "output_file": "b.mp4", "stream_id": 1, "ebu_pass1": {"input_i": -21.75, "normalization_type": "dynamic"},
          "ebu_pass2": {"input_i": -21.75, "output_i": -16.0, "normalization_type": "linear"}, "mean": null, "max": null, "status": "normalized"}]
        """#
        XCTAssertEqual(NormalizePlanner.parseReport(normalized), .init(skipped: false, normalizationType: "linear"))
        let skipped = #"[{"input_file": "a.mp4", "ebu_pass1": {"input_i": -16.06}, "ebu_pass2": null, "status": "skipped"}]"#
        XCTAssertEqual(NormalizePlanner.parseReport(skipped), .init(skipped: true, normalizationType: nil))
        XCTAssertEqual(NormalizePlanner.parseReport("not json"), .init(skipped: false, normalizationType: nil))
    }

    // MARK: - loudnorm（试听）

    func testLoudnormPasses() {
        XCTAssertEqual(NormalizePlanner.firstPassLoudnorm(NormalizeOptions()), "i=-16.00:lra=7.00:tp=-1.50:offset=0.00")
        XCTAssertEqual(NormalizePlanner.firstPassLoudnorm(NormalizeOptions(preset: .strong)), "i=-16.00:lra=5.00:tp=-1.50:offset=0.00")
        let measured = LoudnessStats(integrated: -30.5, truePeak: -12.25, range: 0.4, threshold: -40.6, targetOffset: 0.3)
        // “只统一音量”：目标范围 = 原来的范围，限制在 1…50。
        XCTAssertEqual(NormalizePlanner.secondPassLoudnorm(NormalizeOptions(), measured: measured),
                       "i=-16.00:lra=1.00:tp=-1.50:offset=0.30:measured_i=-30.50:measured_lra=0.40:measured_tp=-12.25:measured_thresh=-40.60:linear=true")
        XCTAssertTrue(NormalizePlanner.secondPassLoudnorm(NormalizeOptions(preset: .flatten), measured: measured).hasPrefix("i=-16.00:lra=7.00:"))
    }

    func testAuditionArguments() {
        let options = NormalizeOptions(ducks: [VolumeDuck(start: 10, end: 10.3, gain: -12)])
        let stats = LoudnessStats(integrated: -30, truePeak: -10, range: 5)
        let out = URL(fileURLWithPath: "/tmp/a.m4a")
        let args = NormalizePlanner.auditionArguments(
            input: input, start: 8, duration: 15, options: options, stats: stats, measured: stats, output: out)
        XCTAssertEqual(Array(args.prefix(9)), ["-hide_banner", "-nostdin", "-n", "-progress", "pipe:1", "-nostats", "-ss", "8.000", "-i"])
        XCTAssertEqual(args[args.firstIndex(of: "-t")! + 1], "15.000")
        XCTAssertEqual(args[args.firstIndex(of: "-map")! + 1], "0:a:0")
        let af = args[args.firstIndex(of: "-af")! + 1]
        XCTAssertTrue(af.hasPrefix("loudnorm=i=-16.00:"), af)
        XCTAssertTrue(af.hasSuffix(#",volume=-12.0dB:enable='between(t\,2.000\,2.300)',aresample=48000"#), af)
        XCTAssertEqual(args.last, out.path)
    }

    // MARK: - 检测

    func testAnalyzerArgumentsEscapeMomentaryPath() {
        let momentary = URL(fileURLWithPath: "/tmp/a b,c:d'e[f].txt")
        let args = LoudnessAnalyzer.arguments(input: input, momentaryFile: momentary)
        let af = args[args.firstIndex(of: "-af")! + 1]
        XCTAssertEqual(af, #"ebur128=metadata=1,ametadata=mode=print:key=lavfi.r128.M:file=/tmp/a b\,c\\:d\\\'e\[f\].txt,loudnorm=print_format=json"#)
        XCTAssertEqual(args[args.firstIndex(of: "-map")! + 1], "0:a:0")
        XCTAssertEqual(Array(args.suffix(3)), ["-f", "null", "-"])
        let plain = LoudnessAnalyzer.arguments(input: input, momentaryFile: nil, preFilters: "highpass=f=80", loudnorm: "i=-16")
        XCTAssertEqual(plain[plain.firstIndex(of: "-af")! + 1], "highpass=f=80,loudnorm=i=-16:print_format=json")
    }

    func testParseStats() throws {
        let stderr = """
        size=N/A time=00:00:10.00 bitrate=N/A speed= 300x
        [Parsed_loudnorm_2 @ 0x5590d95be680]
        {
        \t"input_i" : "-26.03",
        \t"input_tp" : "-8.97",
        \t"input_lra" : "14.10",
        \t"input_thresh" : "-44.18",
        \t"output_i" : "-24.47",
        \t"output_tp" : "-3.76",
        \t"output_lra" : "2.60",
        \t"output_thresh" : "-36.99",
        \t"normalization_type" : "dynamic",
        \t"target_offset" : "0.47"
        }
        """
        let stats = try LoudnessAnalyzer.parseStats(stderr)
        XCTAssertEqual(stats, LoudnessStats(integrated: -26.03, truePeak: -8.97, range: 14.1, threshold: -44.18, targetOffset: 0.47))
        XCTAssertEqual(stats.summary, "-26.0 LUFS · 真峰值 -9.0 dBTP · 范围 14.1 LU")

        let silent = #"{ "input_i" : "-inf", "input_tp" : "-inf", "input_lra" : "0.00", "input_thresh" : "-70.00", "target_offset" : "inf" }"#
        XCTAssertThrowsError(try LoudnessAnalyzer.parseStats(silent)) { XCTAssertEqual($0 as? LoudnessError, .silent) }
        XCTAssertThrowsError(try LoudnessAnalyzer.parseStats("no json here")) { XCTAssertEqual($0 as? LoudnessError, .unparsable) }
    }

    func testParseMomentary() {
        let text = """
        frame:0    pts:0       pts_time:0
        lavfi.r128.M=-120.691
        frame:1    pts:4800    pts_time:0.1
        lavfi.r128.M=-120.691
        frame:2    pts:9600    pts_time:0.2
        lavfi.r128.M=-23.400
        """
        let m = LoudnessAnalyzer.parseMomentary(text)
        XCTAssertEqual(m.times, [0, 0.1, 0.2])
        XCTAssertEqual(m.values, [-120.691, -120.691, -23.4])
    }

    func testBurstDetection() {
        // 整体 -30；阈值 -20。0.0–0.2 秒的 -120 是窗口没填满，忽略。
        var times: [Float] = []
        var values: [Float] = []
        for i in 0..<100 {
            let t = Float(i) / 10
            times.append(t)
            var v: Float = -31
            if i < 3 { v = -120 }
            if (30...33).contains(i) { v = -15 }     // 3.0–3.3
            if i == 36 { v = -18 }                   // 3.6：和上一段相隔 0.3 秒，合并
            if (70...71).contains(i) { v = -12 }     // 7.0–7.1
            values.append(v)
        }
        let bursts = LoudnessBursts.detect(MomentaryLoudness(times: times, values: values), integrated: -30, margin: 10)
        XCTAssertEqual(bursts.count, 2)
        XCTAssertEqual(bursts[0].start, 2.6, accuracy: 0.001, "窗口 0.4 秒：从第一个超标点前 0.4 秒开始")
        XCTAssertEqual(bursts[0].end, 3.6, accuracy: 0.001)
        XCTAssertEqual(bursts[0].peak, -15, accuracy: 0.001)
        XCTAssertEqual(bursts[1].start, 6.6, accuracy: 0.001)
        XCTAssertEqual(bursts[1].end, 7.1, accuracy: 0.001)
        XCTAssertTrue(LoudnessBursts.detect(MomentaryLoudness(times: times, values: values), integrated: -30, margin: 20).isEmpty)
        // 开头就超标：不会小于 0。
        let early = LoudnessBursts.detect(MomentaryLoudness(times: [0.1], values: [-5]), integrated: -30, margin: 10)
        XCTAssertEqual(early.first?.start, 0)
    }

    func testDuckParsing() {
        XCTAssertEqual(VolumeDuck.parse("10-10.3"), VolumeDuck(start: 10, end: 10.3, gain: -12))
        XCTAssertEqual(VolumeDuck.parse("1:23.4-1:24@-9"), VolumeDuck(start: 83.4, end: 84, gain: -9))
        XCTAssertEqual(VolumeDuck.parse("2-3@6dB"), VolumeDuck(start: 2, end: 3, gain: -6))
        XCTAssertNil(VolumeDuck.parse("3-2"))
        XCTAssertNil(VolumeDuck.parse("abc"))
        XCTAssertNil(VolumeDuck.parse("1-2@0"))
    }

    func testFilterGraphEscaping() {
        XCTAssertEqual(FilterGraph.escapeOptionValue("/plain/path.txt"), "/plain/path.txt")
        XCTAssertEqual(FilterGraph.escapeOptionValue("a:b"), #"a\\:b"#)
        XCTAssertEqual(FilterGraph.escapeOptionValue("a,b;c"), #"a\,b\;c"#)
    }

    // MARK: - 缓存

    func testCacheRoundTripAndInvalidation() throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = LoudnessCache(directory: dir.appendingPathComponent("cache"), maxEntries: 2)
        let file = dir.appendingPathComponent("v.mp4")
        try Data("abc".utf8).write(to: file)
        XCTAssertNil(cache.analysis(for: file))

        let analysis = LoudnessAnalysis(
            stats: LoudnessStats(integrated: -20, truePeak: -3, range: 6),
            momentary: MomentaryLoudness(times: [0.1, 0.2], values: [-21.5, -19]))
        cache.store(analysis, for: file)
        XCTAssertEqual(cache.analysis(for: file), analysis)

        // 文件改过（大小变了）：缓存失效。
        try Data("abcd".utf8).write(to: file)
        XCTAssertNil(cache.analysis(for: file))

        // 超过条目上限时删除最旧的。
        for i in 0..<4 {
            let other = dir.appendingPathComponent("o\(i).mp4")
            try Data("\(i)".utf8).write(to: other)
            cache.store(analysis, for: other)
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        XCTAssertEqual(entries.count, 2)
    }

    func testResultComparison() {
        let before = LoudnessStats(integrated: -31.2, truePeak: -12, range: 6.1)
        let after = LoudnessStats(integrated: -16, truePeak: -2.1, range: 6)
        let done = VolumeResult(source: input, output: output, before: before, after: after)
        XCTAssertEqual(done.comparison, "-31.2 → -16.0 LUFS，真峰值 -12.0 → -2.1 dBTP，范围 6.1 → 6.0 LU")
        XCTAssertFalse(done.skipped)
        let skipped = VolumeResult(source: input, output: nil, before: before, after: nil)
        XCTAssertTrue(skipped.skipped)
        XCTAssertTrue(skipped.comparison.contains("跳过"))
    }
}
