import SkimCore
import SwiftUI

/// 音量面板。平时只显示结论（偏低 / 正常 / 偏高）、一个刻度和“调到正常音量”按钮；
/// 具体数值（LUFS / dBTP / LRA）、强度、喷麦、削波修复、局部压低和 15 秒试听都在“高级”里。
struct VolumePanel: View {
    let player: PlayerController
    @Bindable var volume: VolumeController
    let model: AppModel
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            simpleRow
            if volume.detection == .ready, !volume.bursts.isEmpty {
                burstHint
            }
            if let result = volume.lastResult {
                resultRow(result)
            }
            DisclosureGroup("高级", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    if volume.detection == .ready { statusRow }
                    optionsRow
                    if volume.detection == .ready {
                        burstSection
                    }
                    actionRow
                }
                .padding(.top, 4)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 简单视图

    @ViewBuilder
    private var simpleRow: some View {
        HStack(spacing: 12) {
            switch volume.detection {
            case .ready:
                if let stats = volume.analysis?.stats {
                    verdictView(LoudnessVerdict.of(stats), stats: stats)
                }
            case .idle, .detecting, .failed:
                statusRow
            }
            Spacer(minLength: 8)
            if volume.detection == .ready, let button = mainButtonTitle {
                Button(button) { model.exportVolume(volume) }
                    .buttonStyle(.borderedProminent)
                    .help("生成调好音量的新文件（原名_norm），视频不重新编码，原文件不变")
            }
            Button("批量…") { model.openBatchWindow(.volume) }
                .help("一次拖入多个视频，统一调到正常音量")
        }
    }

    private func verdictView(_ verdict: LoudnessVerdict, stats: LoudnessStats) -> some View {
        HStack(spacing: 10) {
            Image(systemName: verdict.needsFix ? "speaker.wave.2.fill" : "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(verdict.needsFix ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(verdict.title).font(.headline)
                Text(verdict.detail).foregroundStyle(.secondary)
            }
            LoudnessScale(integrated: stats.integrated)
                .frame(width: 200, height: 26)
                .help("绿色是正常范围（一般的网络视频、手机视频都在这里）。竖线是这个视频的位置。")
        }
    }

    /// 主按钮：音量不正常时“调到正常音量”；正常但勾了压低爆音时“压低突然很响的地方”。
    private var mainButtonTitle: String? {
        guard let stats = volume.analysis?.stats else { return nil }
        if LoudnessVerdict.of(stats).needsFix { return "调到正常音量" }
        if !volume.options.ducks.isEmpty { return "压低突然很响的地方" }
        return nil
    }

    private var burstHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text("有 \(volume.bursts.count) 处突然很响（时间轴上的红色标记，点一下可以听）")
            Toggle("处理时压低这些地方", isOn: Binding(
                get: { volume.allBurstsDucked },
                set: { volume.setDuckAllBursts($0) }))
            Spacer(minLength: 0)
        }
    }

    // MARK: - 检测结果

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 10) {
            switch volume.detection {
            case .idle:
                Text("还没有检测音量。").foregroundStyle(.secondary)
                Button("检测") { volume.detect() }
            case .detecting:
                if let p = volume.detectionProgress {
                    ProgressView(value: p).frame(width: 140)
                    Text("正在检测音量… \(Int(p * 100))%").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("正在检测音量…").foregroundStyle(.secondary)
                }
                Button("取消") { volume.cancelDetection() }
            case .ready:
                if let stats = volume.analysis?.stats {
                    stat("整体响度", String(format: "%.1f LUFS", stats.integrated),
                         help: "整个视频的平均响度。常见目标：-16 LUFS（手机、网络视频），-23 LUFS（电视）。")
                    stat("真峰值", String(format: "%.1f dBTP", stats.truePeak),
                         help: "最响的瞬间。接近或超过 0 dBTP 时可能有爆音或削波。")
                    stat("响度范围", String(format: "%.1f LU", stats.range),
                         help: "声音起伏有多大（LRA）。数字越大，忽大忽小越明显。")
                }
            case .failed(let message, let log):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                if let log {
                    Button("复制完整命令和日志") { AppModel.copyToPasteboard(log) }
                }
                Button("重试") { volume.detect() }
            }
        }
    }

    private func stat(_ title: String, _ value: String, help: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
        .help(help)
    }

    // MARK: - 处理选项

    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Stepper(value: $volume.options.targetLoudness, in: -30...(-10), step: 0.5) {
                    Text("目标 \(number(volume.options.targetLoudness)) LUFS")
                }
                .fixedSize()
                .help("处理后的整体响度")
                Stepper(value: $volume.options.truePeak, in: -6...0, step: 0.5) {
                    Text("真峰值 ≤ \(number(volume.options.truePeak)) dBTP")
                }
                .fixedSize()
                .help("处理后最响的瞬间不超过这个值")
                Picker("强度", selection: $volume.options.preset) {
                    ForEach(LoudnessPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("减少喷麦声", isOn: $volume.options.highpass)
                    .help("highpass=f=80：去掉 80 Hz 以下的低频（“噗”声），会让音乐的低音变弱一点")
                Toggle("削波修复", isOn: $volume.options.declip)
                    .help("adeclip：修复声音过载造成的破音。只能改善，不能完全恢复；处理比较慢")
            }
            HStack(spacing: 4) {
                Text(volume.options.preset.explanation)
                if volume.options.declip {
                    Text("削波修复只能改善，不能完全恢复。")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 爆音和局部压低

    private var burstSection: some View {
        let bursts = volume.bursts
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(bursts.isEmpty ? "没有爆音" : "爆音 \(bursts.count) 处")
                    .foregroundStyle(bursts.isEmpty ? Color.secondary : Color.red)
                    .help("短时响度（每 0.1 秒）比整体响度高出阈值的地方，时间轴上用红色标出；点红色标记可以跳过去试听")
                Stepper(value: $volume.burstMargin, in: 3...30, step: 1) {
                    Text("阈值：整体 + \(Int(volume.burstMargin)) LU")
                }
                .fixedSize()
                Stepper(value: $volume.duckGain, in: -30...(-1), step: 1) {
                    Text("新加的压低 \(Int(volume.duckGain)) dB")
                }
                .fixedSize()
                Button("把选区加进压低列表") {
                    volume.addDuck(start: player.selection.start, end: player.selection.end)
                }
                .disabled(player.selection.isFull)
                .help("用 I / O 选一段，再点这里：处理时把这一段的音量降低")
            }
            if !bursts.isEmpty || !volume.options.ducks.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(bursts, id: \.self) { burst in
                            burstRow(burst)
                        }
                        ForEach(Array(volume.options.ducks.enumerated()), id: \.offset) { index, duck in
                            duckRow(index, duck)
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
    }

    private func burstRow(_ burst: LoudnessBurst) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text("\(Timecode.format(burst.start)) – \(Timecode.format(burst.end))")
                .font(.system(.body, design: .monospaced))
            Text(String(format: "最高 %.1f LUFS", burst.peak)).foregroundStyle(.secondary)
            Button("跳过去听") { player.play(from: burst.start - 1) }
                .help("从这里前 1 秒开始播放")
            Toggle("处理时压低", isOn: Binding(
                get: { volume.isDucked(burst) },
                set: { _ in volume.toggleDuck(burst) }))
            Spacer(minLength: 0)
        }
    }

    private func duckRow(_ index: Int, _ duck: VolumeDuck) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.minus").foregroundStyle(.orange)
            Text("压低 \(Timecode.format(duck.start)) – \(Timecode.format(duck.end))")
                .font(.system(.body, design: .monospaced))
            Stepper(value: Binding(
                get: { duck.gain },
                set: { volume.setDuckGain(at: index, $0) }), in: -30...(-1), step: 1) {
                Text("\(Int(duck.gain)) dB")
            }
            .fixedSize()
            Button { volume.removeDuck(at: index) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("不压低这一段")
            Spacer(minLength: 0)
        }
    }

    // MARK: - 试听和生成

    private var actionRow: some View {
        HStack(spacing: 10) {
            switch volume.audition {
            case .idle:
                Button("试听 15 秒") { volume.startAudition(at: player.playhead) }
                    .disabled(!volume.canAudition)
                    .help("从播放头开始，生成 15 秒处理后的声音，可以和原声来回切换")
            case .preparing:
                if let p = volume.auditionProgress {
                    ProgressView(value: p).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("正在生成试听…").foregroundStyle(.secondary)
                Button("取消") { volume.stopAudition() }
            case .playing:
                Picker("", selection: $volume.hearsProcessed) {
                    Text("原声").tag(false)
                    Text("处理后").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("无缝切换，对比处理前后的声音")
                Button("停止试听") { volume.stopAudition() }
            }
            if let error = volume.auditionError {
                Text(error).foregroundStyle(.red).lineLimit(1)
                if let log = volume.auditionLog {
                    Button("复制完整命令和日志") { AppModel.copyToPasteboard(log) }
                }
            }
            Spacer(minLength: 8)
            Button("生成 \(volume.source.deletingPathExtension().lastPathComponent)_norm") {
                model.exportVolume(volume)
            }
            .help("视频直接复制，只重新编码音频，写成新文件；原文件不变。已经接近目标的视频会跳过。")
        }
    }

    private func resultRow(_ result: VolumeResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.skipped ? "checkmark.circle" : "checkmark.circle.fill").foregroundStyle(.green)
            Text("处理前 → 处理后：" + result.comparison)
                .lineLimit(2)
                .textSelection(.enabled)
            if let note = result.note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let output = result.output {
                Button("在 Finder 中显示") { AppModel.revealInFinder(output) }
            }
        }
    }

    private func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// 音量刻度：从“很小”到“很大”，绿色是正常范围，竖线是这个视频的位置。
private struct LoudnessScale: View {
    let integrated: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let lo = LoudnessVerdict.position(LoudnessVerdict.normalRange.lowerBound) * w
            let hi = LoudnessVerdict.position(LoudnessVerdict.normalRange.upperBound) * w
            let x = LoudnessVerdict.position(integrated) * w
            VStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 6)
                    Rectangle().fill(Color.green.opacity(0.7)).frame(width: hi - lo, height: 6).offset(x: lo)
                    Rectangle().fill(Color.primary).frame(width: 3, height: 14).offset(x: min(max(x - 1.5, 0), w - 3))
                }
                .frame(height: 14)
                HStack {
                    Text("小").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("正常").font(.caption2).foregroundStyle(.green)
                    Spacer()
                    Text("大").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
