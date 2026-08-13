import SwiftUI

struct EffectAnalysisPanel: View {
    @EnvironmentObject private var store: PhotoStore
    @ObservedObject var item: PhotoItem

    private var scope: EffectAnalysisScope { store.effectAnalysisScope }
    private var analysis: ImageAnalysisData? {
        if let cached = item.cachedAnalysis(for: scope.mode) { return cached }
        return store.hdrMode == scope.mode ? item.analysis : nil
    }
    private var histogram: HistogramData? {
        if let cached = item.cachedHistogram(for: scope.mode) { return cached }
        return store.hdrMode == scope.mode ? item.histogram : nil
    }
    private var loading: Bool {
        item.loading || item.analysisLoadingModes.contains(scope.mode)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("效果分析").font(.headline)
                        Text(item.url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(scope == .hdr ? "Gain Map" : "基础图")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(scope == .hdr ? .orange.opacity(0.75) : .white.opacity(0.18))
                        .clipShape(Capsule())
                }

                Picker("效果维度", selection: $store.effectAnalysisScope) {
                    ForEach(EffectAnalysisScope.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text(scope.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let analysis {
                    if scope == .hdr {
                        HDREffectDashboard(item: item, analysis: analysis,
                                           histogram: histogram,
                                           sdrAnalysis: item.cachedAnalysis(for: .sdr),
                                           sdrHistogram: item.cachedHistogram(for: .sdr))
                    } else {
                        SDREffectDashboard(item: item, analysis: analysis, histogram: histogram)
                    }
                } else if loading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("正在准备 (scope.rawValue) 数据…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    Text("暂无 (scope.rawValue) 分析数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(10)
        }
        .task(id: "\(item.id.uuidString)-\(scope.rawValue)") {
            store.ensureEffectAnalysis(item, scope: scope)
        }
    }
}

private struct SDREffectDashboard: View {
    @ObservedObject var item: PhotoItem
    let analysis: ImageAnalysisData
    let histogram: HistogramData?

    private var channelClipSummary: String {
        guard let histogram else { return "无可靠数据" }
        return "\(formatPercent(histogram.redClipRatio)) / \(formatPercent(histogram.greenClipRatio)) / \(formatPercent(histogram.blueClipRatio))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EffectSection(title: "SDR 可见效果", subtitle: "以 SDR white = 1.0 为显示参考") {
                ToneDistributionBar(analysis: analysis, isHDR: false)
                MetricGrid(items: [
                    ("有效动态范围", formatEV(analysis.effectiveDynamicRangeEV)),
                    ("影调对比", formatEV(analysis.tonalContrastEV)),
                    ("中位亮度", formatNumber(analysis.medianLuminance)),
                    ("高光安全", formatPercent(1 - analysis.sdrWhiteRatio))
                ])
            }

            EffectSection(title: "影调与高光", subtitle: "区分近黑、正常曝光和 SDR white 以上像素") {
                AnalysisRows(rows: [
                    ("P01 / P99 亮度 Y", pair(analysis.percentile01Luminance, analysis.percentile99Luminance)),
                    ("平均亮度 Y", formatNumber(analysis.meanLuminance)),
                    ("阴影近黑（Y ≤ 0.001）", formatPercent(analysis.shadowClipRatio)),
                    ("SDR white 以上", formatPercent(analysis.sdrWhiteRatio)),
                    ("R / G / B 高光裁切", channelClipSummary)
                ])
                if let histogram {
                    CompactHistogramStrip(histogram: histogram, domain: .sdr)
                        .frame(height: 52)
                }
            }

            EffectSection(title: "色彩与肤色", subtitle: "全图色彩分布，肤色区域由 Vision 自动检测") {
                MetricGrid(items: [
                    ("平均饱和度", formatPercent(analysis.meanSaturation)),
                    ("P95 饱和度", formatPercent(analysis.percentile95Saturation)),
                    ("平均色相", formatDegrees(analysis.meanHueDegrees)),
                    ("RGB 均值差", formatNumber(analysis.neutralBalance))
                ])
                SkinToneIndicatorView(stats: analysis.skin)
                    .frame(height: analysis.skin.faceAnalysisState == "未分析" ? 190 : 238)
                Text("肤色线是色相方向参考；人脸统计不需要额外开关，会在对应预览解码后自动更新。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            EffectSection(title: "细节", subtitle: "当前采样分辨率下的归一化局部梯度") {
                AnalysisRows(rows: [
                    ("细节能量", formatNumber(analysis.detailEnergy)),
                    ("有效采样", "\(analysis.validSampleCount) / \(analysis.sampleCount)")
                ])
            }
        }
    }
}

private struct HDREffectDashboard: View {
    let item: PhotoItem
    let analysis: ImageAnalysisData
    let histogram: HistogramData?
    let sdrAnalysis: ImageAnalysisData?
    let sdrHistogram: HistogramData?

    private var display: HDRDisplayInfo { HDRDisplayInfo.current }
    private var measuredPeakEV: Double {
        max(0, log2(max(1, analysis.maximumLuminance ?? 1)))
    }
    private var contentEV: Double {
        min(4, max(measuredPeakEV, analysis.p99HeadroomEV ?? 0))
    }
    private var displayEV: Double {
        min(4, max(0, display.capabilityHeadroomEV ?? display.headroomEV ?? 0))
    }
    private var unsupportedRatio: Double {
        guard let histogram, histogram.domain == .hdr,
              histogram.sampleCount > 0 else { return 0 }
        let threshold = min(255, max(128, 128 + Int((displayEV / 4 * 127).rounded())))
        let count = histogram.luminance[threshold...].reduce(0, +)
        return Double(count) / Double(histogram.sampleCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EffectSection(title: "HDR 内容效果", subtitle: "由原始 Base Image + Gain Map 受控重建；不使用当前屏幕输出作为分析输入") {
                HDRRangeMeter(contentEV: contentEV, displayEV: displayEV,
                              p99EV: analysis.p99HeadroomEV ?? 0)
                    .frame(height: 76)
                MetricGrid(items: [
                    ("实际内容峰值", formatEV(measuredPeakEV)),
                    ("P99 头部", formatEV(analysis.p99HeadroomEV)),
                    ("HDR 像素占比", formatPercent(analysis.hdrPixelRatio)),
                    ("分析输入", analysis.sourceDriven ? "源数据重建" : "系统回退")
                ])
                Text("分析依据：\(analysis.measurementBasis)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            EffectSection(title: "HDR 源数据", subtitle: "Gain Map 原始像素统计与 ISO 21496-1 参数；描述图片自身的 HDR 能力") {
                MetricGrid(items: [
                    ("Base HDR Headroom", formatEV(item.metadata.gainMap.baseHDRHeadroom)),
                    ("Alternate HDR Headroom", formatEV(item.metadata.gainMap.alternateHDRHeadroom)),
                    ("Gain Map 实际增益 P99", formatEV(item.metadata.gainMap.sourceStats.gainEVP99)),
                    ("Base → Alternate 提升 P95", formatEV(item.metadata.gainMap.sourceStats.reconstructedLiftEVP95))
                ])
                AnalysisRows(rows: item.metadata.gainMap.sourceRows)
            }

            EffectSection(title: "HDR 内容影调与高光行为", subtitle: "按 1 EV 档位拆分，统计受控重建后的内容亮度") {
                HDRStopDistribution(analysis: analysis)
                AnalysisRows(rows: [
                    ("阴影近黑（Y ≤ 0.001）", formatPercent(analysis.shadowClipRatio)),
                    ("HDR 映射前后 P05", pair(sdrAnalysis?.percentile05Luminance, analysis.percentile05Luminance)),
                    ("HDR 映射前后影调对比", deltaEV(sdrAnalysis?.tonalContrastEV, analysis.tonalContrastEV))
                ])
                if let histogram {
                    CompactHistogramStrip(histogram: histogram, domain: .hdr)
                        .frame(height: 58)
                }
            }

            EffectSection(title: "当前屏幕显示能力", subtitle: "这些数据只描述当前显示设备能显示多少，不计入图片 HDR 质量") {
                MetricGrid(items: [
                    ("屏幕能力", formatEV(displayEV)),
                    ("屏幕可显示内容", formatPercent(1 - unsupportedRatio)),
                    ("超出屏幕能力", formatPercent(unsupportedRatio)),
                    ("屏幕 API", display.api)
                ])
                AnalysisRows(rows: [
                    ("Overrange（GPU view）", display.overrange ? "是" : "否"),
                    ("HDR screen info", String(format: "max=%.2f, pot=%.2f, ref=%.2f", display.maximum, display.potential, display.reference))
                ])
            }

            EffectSection(title: "HDR 色彩体积", subtitle: "用饱和度、色相和高光色彩信号描述 Gain Map 带来的变化") {
                MetricGrid(items: [
                    ("平均饱和度变化", deltaPercent(sdrAnalysis?.meanSaturation, analysis.meanSaturation)),
                    ("P95 饱和度变化", deltaPercent(sdrAnalysis?.percentile95Saturation, analysis.percentile95Saturation)),
                    ("HDR 高光饱和度", formatPercent(analysis.hdrHighlightMeanSaturation)),
                    ("高光色彩变化", deltaPercent(sdrAnalysis?.sdrHighlightMeanSaturation,
                                                   analysis.hdrHighlightMeanSaturation))
                ])
                AnalysisRows(rows: [
                    ("HDR 平均色相", formatDegrees(analysis.meanHueDegrees)),
                    ("SDR / HDR RGB 均值差", "\(formatNumber(sdrAnalysis?.neutralBalance)) / \(formatNumber(analysis.neutralBalance))"),
                    ("HDR 肤色候选占比", formatPercent(analysis.skin.candidateRatio))
                ])
            }

            HDRTechnicalRouteView(metadata: item.metadata)

            EffectSection(title: "人脸肤色", subtitle: "基于 HDR 内容受控重建结果的人脸区域统计") {
                SkinToneIndicatorView(stats: analysis.skin)
                    .frame(height: analysis.skin.faceAnalysisState == "未分析" ? 190 : 238)
            }
        }
    }
}

private struct EffectSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(9)
        .background(.black.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct MetricGrid: View {
    let items: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.0).font(.caption2).foregroundStyle(.secondary)
                    Text(item.1).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .background(.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

private struct AnalysisRows: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(row.1).monospacedDigit().multilineTextAlignment(.trailing)
                }
                .font(.caption)
            }
        }
    }
}

private struct ToneDistributionBar: View {
    let analysis: ImageAnalysisData
    let isHDR: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                let shadow = min(1, max(0, analysis.shadowClipRatio))
                let highlight = min(1 - shadow, max(0, analysis.sdrWhiteRatio))
                let middle = max(0, 1 - shadow - highlight)
                HStack(spacing: 1) {
                    Rectangle().fill(.blue.opacity(0.8)).frame(width: proxy.size.width * shadow)
                    Rectangle().fill(.white.opacity(0.5)).frame(width: proxy.size.width * middle)
                    Rectangle().fill(isHDR ? .orange.opacity(0.9) : .red.opacity(0.8))
                        .frame(width: proxy.size.width * highlight)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 12)
            HStack {
                Text("阴影 \(formatPercent(analysis.shadowClipRatio))")
                Spacer()
                Text("中间调 \(formatPercent(max(0, 1 - analysis.shadowClipRatio - analysis.sdrWhiteRatio)))")
                Spacer()
                Text(isHDR ? "HDR \(formatPercent(analysis.hdrPixelRatio))" : "白点以上 \(formatPercent(analysis.sdrWhiteRatio))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

private struct HDRRangeMeter: View {
    let contentEV: Double
    let displayEV: Double
    let p99EV: Double

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let split = width * 0.5
                let hdrWidth = width - split
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle().fill(.white.opacity(0.28)).frame(width: split)
                        Rectangle().fill(.red.opacity(0.42)).frame(width: hdrWidth)
                    }
                    Rectangle().fill(.yellow.opacity(0.86))
                        .frame(width: split + hdrWidth * CGFloat(displayEV / 4))
                    Path { path in
                        path.move(to: CGPoint(x: split, y: 0))
                        path.addLine(to: CGPoint(x: split, y: proxy.size.height))
                        for stop in 1...3 {
                            let x = split + hdrWidth * CGFloat(stop) / 4
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        }
                    }
                    .stroke(.black.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    Rectangle().fill(.white)
                        .frame(width: 2)
                        .offset(x: split + hdrWidth * CGFloat(min(4, contentEV) / 4))
                    Rectangle().fill(.white.opacity(0.7))
                        .frame(width: 1)
                        .offset(x: split + hdrWidth * CGFloat(min(4, p99EV) / 4))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 24)
            HStack(spacing: 0) {
                Text("SDR")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("+1 EV")
                Text("+2 EV")
                Text("+3 EV")
                Text("+4 EV")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack {
                Circle().fill(.yellow).frame(width: 6, height: 6)
                Text("屏幕能力 \(formatEV(displayEV))")
                Spacer()
                Circle().fill(.white).frame(width: 6, height: 6)
                Text("内容峰值 \(formatEV(contentEV))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

private struct HDRStopDistribution: View {
    let analysis: ImageAnalysisData

    private var bins: [(String, Double)] {
        [
            ("0–1 EV", max(0, analysis.hdrPixelRatio - analysis.hdrStop1Ratio)),
            ("1–2 EV", max(0, analysis.hdrStop1Ratio - analysis.hdrStop2Ratio)),
            ("2–3 EV", max(0, analysis.hdrStop2Ratio - analysis.hdrStop3Ratio)),
            ("3–4 EV", max(0, analysis.hdrStop3Ratio - analysis.hdrStop4Ratio)),
            (">4 EV", analysis.hdrStop4Ratio)
        ]
    }

    var body: some View {
        VStack(spacing: 5) {
            ForEach(bins, id: \.0) { bin in
                HStack(spacing: 6) {
                    Text(bin.0).frame(width: 50, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.10))
                            Capsule().fill(.orange.opacity(0.82))
                                .frame(width: proxy.size.width * CGFloat(min(1, bin.1 * 4)))
                        }
                    }
                    .frame(height: 7)
                    Text(formatPercent(bin.1)).frame(width: 48, alignment: .trailing)
                }
                .font(.caption2.monospacedDigit())
            }
        }
    }
}

private struct CompactHistogramStrip: View {
    let histogram: HistogramData
    let domain: HistogramData.Domain

    var body: some View {
        Canvas { context, size in
            let maxValue = max(histogram.red.max() ?? 0,
                               max(histogram.green.max() ?? 0, histogram.blue.max() ?? 0))
            guard maxValue > 0 else { return }
            if domain == .hdr {
                context.fill(Path(CGRect(x: size.width * 0.5, y: 0,
                                          width: size.width * 0.5, height: size.height)),
                             with: .color(.orange.opacity(0.10)))
                var divider = Path()
                divider.move(to: CGPoint(x: size.width * 0.5, y: 0))
                divider.addLine(to: CGPoint(x: size.width * 0.5, y: size.height))
                context.stroke(divider, with: .color(.white.opacity(0.35)), lineWidth: 1)
            }
            draw(histogram.red, color: .red, maxValue: maxValue, context: &context, size: size)
            draw(histogram.green, color: .green, maxValue: maxValue, context: &context, size: size)
            draw(histogram.blue, color: .blue, maxValue: maxValue, context: &context, size: size)
        }
        .background(.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func draw(_ bins: [Int], color: Color, maxValue: Int,
                      context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        let denominator = log(Double(maxValue) + 1)
        for index in bins.indices {
            let x = CGFloat(index) / CGFloat(max(1, bins.count - 1)) * size.width
            let value = log(Double(bins[index]) + 1) / denominator
            let y = size.height - 2 - CGFloat(value) * max(1, size.height - 4)
            if index == bins.startIndex { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1)
    }
}

private struct HDRTechnicalRouteView: View {
    let metadata: PhotoMetadata
    private var info: GainMapInfo { metadata.gainMap }

    var body: some View {
        EffectSection(title: "技术路线证据", subtitle: "只展示文件中可观测的 Gain Map 证据，不把元数据误判为完整渲染管线") {
            AnalysisRows(rows: [
                ("Gain Map 类型", info.available ? info.kind : "未发现"),
                ("多通道", info.multichannel.map { $0 ? "是（RGB/多通道）" : "否（单通道证据）" } ?? "无可靠数据"),
                ("Base 图像色彩空间", info.baseColorSpace.isEmpty ? "无可靠数据" : info.baseColorSpace),
                ("Base 传递函数", info.baseTransferFunction.isEmpty ? "无可靠数据" : info.baseTransferFunction),
                ("HDR Alternate 色彩空间", info.alternateColorSpace.isEmpty ? "未单独声明" : info.alternateColorSpace),
                ("HDR 传递函数", info.alternateTransferFunction.isEmpty ? "未单独声明" : info.alternateTransferFunction),
                ("可推断层级", routeDescription)
            ])
        }
    }

    private var routeDescription: String {
        guard info.available else { return "SDR / 无 Gain Map" }
        if info.multichannel == true { return "多通道色彩扩展；仍不能仅凭 JPEG 断定内部为并行渲染" }
        return "亮度 Gain Map；更接近 SDR-first 扩展，但完整 pipeline 需源端证据"
    }
}

private func formatPercent(_ value: Double?) -> String {
    value.map { String(format: "%.2f%%", $0 * 100) } ?? "无可靠数据"
}

private func formatEV(_ value: Double?) -> String {
    value.map { String(format: "%+.2f EV", $0) } ?? "无可靠数据"
}

private func formatNumber(_ value: Double?) -> String {
    value.map { String(format: "%.4f", $0) } ?? "无可靠数据"
}

private func formatDegrees(_ value: Double?) -> String {
    value.map { String(format: "%.1f°", $0) } ?? "无可靠数据"
}

private func pair(_ first: Double?, _ second: Double?) -> String {
    "\(formatNumber(first)) / \(formatNumber(second))"
}

private func deltaEV(_ first: Double?, _ second: Double?) -> String {
    guard let first, let second else { return "无可靠数据" }
    return String(format: "%+.2f EV", second - first)
}

private func deltaPercent(_ first: Double?, _ second: Double?) -> String {
    guard let first, let second else { return "无可靠数据" }
    return String(format: "%+.2f%%", (second - first) * 100)
}
