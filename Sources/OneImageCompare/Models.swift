import AppKit
import CoreGraphics
import Foundation
import Metal
import SwiftUI

enum AppMode: String, Codable { case browser, viewer, compare }
enum HDRMode: String, Codable, CaseIterable, Identifiable {
    case hdr = "HDR"
    case sdr = "SDR 映射"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .hdr: return "HDR（应用 Gain Map）"
        case .sdr: return "SDR 基础图（不应用 Gain Map）"
        }
    }
}
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case neutral = "50% 灰"
    case dark = "深色"
    case light = "浅色"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .dark: return .dark; case .light: return .light; case .neutral: return .dark }
    }
}
enum SortOrder: String, CaseIterable, Identifiable {
    case name = "文件名", captureDate = "拍摄时间", size = "文件大小", added = "导入顺序"
    var id: String { rawValue }
}
enum InspectorTab: String, CaseIterable, Identifiable {
    case gainMap = "Gain Map"
    case photo = "照片信息"
    var id: String { rawValue }
}

enum EffectAnalysisScope: String, CaseIterable, Identifiable {
    case sdr = "SDR效果"
    case hdr = "HDR效果"

    var id: String { rawValue }
    var mode: HDRMode { self == .sdr ? .sdr : .hdr }
    var subtitle: String {
        switch self {
        case .sdr: return "基础图的可见影调、色彩与高光安全"
        case .hdr: return "基于原始 Base + Gain Map 的内容重建；屏幕能力单独显示"
        }
    }
}

struct HistogramData: Codable, Equatable {
    enum Domain: String, Codable {
        case sdr
        case hdr
    }

    var red = Array(repeating: 0, count: 256)
    var green = Array(repeating: 0, count: 256)
    var blue = Array(repeating: 0, count: 256)
    var luminance = Array(repeating: 0, count: 256)
    var domain: Domain = .sdr
    var maximumHDRStops: Double = 4
    var highlightRatio: Double = 0
    var shadowRatio: Double = 0
    var extendedHighlightRatio: Double = 0
    var redClipRatio: Double = 0
    var greenClipRatio: Double = 0
    var blueClipRatio: Double = 0
    var highlightClipRatio: Double = 0
    var displayHighlightClipRatio: Double = 0
    var validSampleCount = 0
    var sampleCount = 0
    var usesExtendedRange = false
    var contentHeadroomEV: Double?
    var displayHeadroomEV: Double?
    var sourceDescription = ""
    var sampleStatus = "无有效采样"

    var isValid: Bool { sampleCount > 0 && validSampleCount > 0 }
    static let empty = HistogramData()
}

struct SkinToneStats: Codable, Equatable {
    var candidateRatio: Double = 0
    var candidateCount = 0
    var meanHueDegrees: Double?
    var hueStdDevDegrees: Double?
    var meanSaturation: Double?
    var lineDeviationDegrees: Double?
    var lineAngleDegrees: Double = 19
    var vectorscopeBins = Array(repeating: 0.0, count: 72 * 24)
    var skinVectorscopeBins = Array(repeating: 0.0, count: 72 * 24)
    // Face analysis is opt-in because Vision detection is more expensive than
    // the full-frame skin candidate pass used for the initial report.
    var faceAnalysisState = "未分析"
    var faceCount = 0
    var faceSampleCount = 0
    var faceCandidateCount = 0
    var faceCandidateRatio: Double = 0
    var faceMeanHueDegrees: Double?
    var faceHueStdDevDegrees: Double?
    var faceMeanSaturation: Double?
    var faceLineDeviationDegrees: Double?
    static let empty = SkinToneStats()
}

struct ImageAnalysisData: Codable, Equatable {
    // The basis is intentionally explicit: a system DecodeToHDR image is a
    // preview rendition, while a source-driven report is built from the base
    // image and the embedded gain map itself.
    var measurementBasis = "解码后的图像像素"
    var sourceDriven = false
    var sampleCount = 0
    var validSampleCount = 0
    var meanLuminance: Double?
    var medianLuminance: Double?
    var percentile01Luminance: Double?
    var percentile05Luminance: Double?
    var percentile95Luminance: Double?
    var percentile99Luminance: Double?
    var effectiveDynamicRangeEV: Double?
    var tonalContrastEV: Double?
    var sdrWhiteRatio: Double = 0
    var extendedHighlightRatio: Double = 0
    var shadowClipRatio: Double = 0
    var meanSaturation: Double?
    var percentile95Saturation: Double?
    var meanHueDegrees: Double?
    var neutralBalance: Double?
    var outOfGamutRatio: Double = 0
    var detailEnergy: Double?
    // HDR effect metrics use the same linear-light luminance samples as the
    // objective tone metrics above. They are deliberately separate from the
    // display-referred histogram bins.
    var maximumLuminance: Double?
    var p99HeadroomEV: Double?
    var hdrPixelRatio: Double = 0
    var hdrStop1Ratio: Double = 0
    var hdrStop2Ratio: Double = 0
    var hdrStop3Ratio: Double = 0
    var hdrStop4Ratio: Double = 0
    var sdrHighlightMeanSaturation: Double?
    var hdrHighlightMeanSaturation: Double?
    var skin = SkinToneStats.empty
    static let empty = ImageAnalysisData()

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.2f%%", $0 * 100) } ?? "无可靠数据"
    }

    var qualityRows: [(String, String)] {
        let p01P99 = [percentile01Luminance, percentile99Luminance]
            .compactMap { $0.map { String(format: "%.4f", $0) } }
            .joined(separator: " / ")
        return [
            ("有效采样", "\(validSampleCount) / \(sampleCount)"),
            ("P01 / P99 亮度 Y", p01P99.isEmpty ? "无可靠数据" : p01P99),
            ("有效动态范围（P01–P99）", effectiveDynamicRangeEV.map { String(format: "%.2f EV", $0) } ?? "无可靠数据"),
            ("SDR 白点以上", percent(sdrWhiteRatio)),
            ("通道超过 +4 EV", percent(extendedHighlightRatio)),
            ("阴影近黑（Y ≤ 0.001）", percent(shadowClipRatio)),
            ("细节能量（归一化梯度）", detailEnergy.map { String(format: "%.4f", $0) } ?? "无可靠数据")
        ]
    }

    var toneRows: [(String, String)] {
        let p05P95 = [percentile05Luminance, percentile95Luminance]
            .compactMap { $0.map { String(format: "%.4f", $0) } }
            .joined(separator: " / ")
        return [
            ("平均亮度 Y", meanLuminance.map { String(format: "%.4f", $0) } ?? "无可靠数据"),
            ("中位亮度 Y", medianLuminance.map { String(format: "%.4f", $0) } ?? "无可靠数据"),
            ("P05 / P95", p05P95.isEmpty ? "无可靠数据" : p05P95),
            ("影调对比（P05–P95）", tonalContrastEV.map { String(format: "%.2f EV", $0) } ?? "无可靠数据")
        ]
    }

    var colorRows: [(String, String)] {
        [
            ("平均饱和度", meanSaturation.map { String(format: "%.2f%%", $0 * 100) } ?? "无可靠数据"),
            ("P95 饱和度", percentile95Saturation.map { String(format: "%.2f%%", $0 * 100) } ?? "无可靠数据"),
            ("平均色相", meanHueDegrees.map { String(format: "%.1f°", $0) } ?? "无可靠数据"),
            ("全图 RGB 均值差", neutralBalance.map { String(format: "%.4f", $0) } ?? "无可靠数据"),
            ("扩展亮度像素（Y > 1）", percent(outOfGamutRatio))
        ]
    }
}

struct HDRInfo: Codable, Equatable {
    var kind = "SDR"
    var transfer = "SDR Gamma"
    var gamut = "未知"
    var bitDepth = 8
    var headroom: Double?
    var maxCLL: Double?
    var maxFALL: Double?
    var confidence = "中"
    var evidence: [String] = []
    var isHDR: Bool { kind != "SDR" }
}

struct MetadataField: Codable, Equatable, Identifiable {
    var id: String { "\(source):\(key)" }
    var key: String
    var value: String
    var source: String
}

struct HDRDisplayInfo: Equatable {
    var api: String
    var overrange: Bool
    var maximum: Double
    var potential: Double
    var reference: Double
    var headroomEV: Double?

    // The potential value is the device/display ceiling. It is useful for
    // annotating which HDR stops can be shown even when the current window's
    // effective maximum is temporarily lower.
    var capabilityHeadroomEV: Double? {
        let capability = max(maximum, potential)
        return capability > 0 ? log2(capability) : nil
    }

    @MainActor
    static var current: HDRDisplayInfo {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let maximum = max(0, screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        let potential = max(0, screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? maximum)
        let reference = max(0, screen?.maximumReferenceExtendedDynamicRangeColorComponentValue ?? 0)
        return HDRDisplayInfo(
            api: MTLCreateSystemDefaultDevice() == nil ? "CPU" : "Metal",
            overrange: maximum > 1.0001,
            maximum: maximum,
            potential: potential,
            reference: reference,
            headroomEV: maximum > 0 ? log2(maximum) : nil
        )
    }

    var rows: [(String, String)] {
        [
            ("API", api),
            ("Overrange（GPU view）", overrange ? "是" : "否"),
            ("HDR screen info", String(format: "max=%.2f, pot=%.2f, ref=%.2f", maximum, potential, reference)),
            ("HDR screen headroom", headroomEV.map { String(format: "%.4f EV", $0) } ?? "未知"),
            ("HDR screen capability", capabilityHeadroomEV.map { String(format: "%.4f EV", $0) } ?? "未知")
        ]
    }
}

struct GainMapSourceStats: Codable, Equatable {
    var available = false
    var sampleCount = 0
    var validSampleCount = 0
    var encodedMean: Double?
    var encodedP01: Double?
    var encodedP50: Double?
    var encodedP99: Double?
    var gainEVMean: Double?
    var gainEVP01: Double?
    var gainEVP50: Double?
    var gainEVP99: Double?
    var gainEVMin: Double?
    var gainEVMax: Double?
    var reconstructedLiftEVMean: Double?
    var reconstructedLiftEVP95: Double?
    var activeRatio = 0.0
    var samplingDescription = ""

    static let unavailable = GainMapSourceStats()
}

struct GainMapInfo: Codable, Equatable {
    var available = false
    var kind = ""
    var minimumVersion: String?
    var writerVersion: String?
    var multichannel: Bool?
    var useBaseColorSpace: Bool?
    var baseHDRHeadroom: Double?
    var alternateHDRHeadroom: Double?
    var baseColorSpace = ""
    var baseTransferFunction = ""
    var alternateColorSpace = ""
    var alternateTransferFunction = ""
    var pixelFormat = ""
    var gainMapMin: [Double] = []
    var gainMapMax: [Double] = []
    var gamma: [Double] = []
    var baseOffset: [Double] = []
    var alternateOffset: [Double] = []
    var resolutionWidth = 0
    var resolutionHeight = 0
    var primaryWidth = 0
    var primaryHeight = 0
    var sourceStats = GainMapSourceStats.unavailable

    static let none = GainMapInfo()

    func apiRows(_ display: HDRDisplayInfo) -> [(String, String)] {
        display.rows
    }

    func headroomRows(hdrHeadroom: Double?) -> [(String, String)] {
        guard available else { return [] }
        return [
            ("HDR Headroom", hdrHeadroom.map { String(format: "%.2f×", $0) } ?? "无可靠数据"),
            ("Alt HDR Headroom", alternateHDRHeadroom.map { String(format: "%+.4f", $0) } ?? "无可靠数据"),
            ("GainMapMax", formatValues(gainMapMax)),
            ("GainMapMin", formatValues(gainMapMin)),
            ("Base HDR Headroom", baseHDRHeadroom.map { String(format: "%+.4f", $0) } ?? "无可靠数据")
        ]
    }

    func remainingRows() -> [(String, String)] {
        guard available else { return [] }
        return [
            ("Minimum Version", minimumVersion ?? "无可靠数据"),
            ("Writer Version", writerVersion ?? "无可靠数据"),
            ("Multichannel", multichannel.map { $0 ? "yes" : "no" } ?? "无可靠数据"),
            ("Use Base Color Space", useBaseColorSpace.map { $0 ? "yes" : "no" } ?? "无可靠数据"),
            ("Base 图像色彩空间", baseColorSpace.isEmpty ? "无可靠数据" : baseColorSpace),
            ("Base 传递函数", baseTransferFunction.isEmpty ? "无可靠数据" : baseTransferFunction),
            ("HDR Alternate 色彩空间", alternateColorSpace.isEmpty ? "未单独声明" : alternateColorSpace),
            ("HDR 传递函数", alternateTransferFunction.isEmpty ? "未单独声明" : alternateTransferFunction),
            ("Gain Map 像素格式", pixelFormat.isEmpty ? "无可靠数据" : pixelFormat),
            ("Gamma", formatValues(gamma)),
            ("BaseOffset", formatValues(baseOffset)),
            ("AlternateOffset", formatValues(alternateOffset))
        ]
    }

    var resolutionRow: (String, String)? {
        guard resolutionWidth > 0, resolutionHeight > 0 else { return nil }
        var value = "\(resolutionWidth) × \(resolutionHeight)"
        if primaryWidth > 0, primaryHeight > 0 {
            let widthScale = Double(primaryWidth) / Double(resolutionWidth)
            let heightScale = Double(primaryHeight) / Double(resolutionHeight)
            if abs(widthScale - heightScale) < 0.01, widthScale >= 1 {
                let roundedScale = widthScale.rounded()
                value += " (1:\(Int(roundedScale)))"
            }
        }
        return ("Gain Map Resolution", value)
    }

    func weight(for display: HDRDisplayInfo) -> Double? {
        guard let baseHDRHeadroom, let alternateHDRHeadroom,
              let headroom = display.capabilityHeadroomEV ?? display.headroomEV,
              alternateHDRHeadroom != baseHDRHeadroom else { return nil }
        let fraction = (headroom - baseHDRHeadroom) / (alternateHDRHeadroom - baseHDRHeadroom)
        let clamped = min(1, max(0, fraction))
        return alternateHDRHeadroom < baseHDRHeadroom ? -clamped : clamped
    }

    private func formatValues(_ values: [Double]) -> String {
        if values.count == 1 { return String(format: "%+.4f", values[0]) }
        let labels = ["R", "G", "B"]
        return values.enumerated().map { index, value in
            let label = index < labels.count ? labels[index] : "C\(index + 1)"
            return "\(label) \(String(format: "%+.4f", value))"
        }.joined(separator: " / ")
    }

    var sourceRows: [(String, String)] {
        guard available else { return [] }
        let stats = sourceStats
        let percent: (Double?) -> String = { value in
            value.map { String(format: "%.2f%%", $0 * 100) } ?? "无可靠数据"
        }
        let number: (Double?) -> String = { value in
            value.map { String(format: "%+.4f", $0) } ?? "无可靠数据"
        }
        return [
            ("原始 Gain Map 采样", stats.validSampleCount > 0
                ? "\(stats.validSampleCount) / \(stats.sampleCount)"
                : "不可读取"),
            ("Gain Map 编码值 P01 / P50 / P99", [stats.encodedP01, stats.encodedP50, stats.encodedP99]
                .map { $0.map { String(format: "%.4f", $0) } ?? "—" }.joined(separator: " / ")),
            ("实际增益 P01 / P50 / P99（EV）", [stats.gainEVP01, stats.gainEVP50, stats.gainEVP99]
                .map { number($0) }.joined(separator: " / ")),
            ("实际增益范围（EV）", "\(number(stats.gainEVMin)) … \(number(stats.gainEVMax))"),
            ("Base → Alternate 实际提升 P95", number(stats.reconstructedLiftEVP95)),
            ("Gain Map 非零区域", percent(stats.activeRatio)),
            ("源数据采样方式", stats.samplingDescription.isEmpty ? "无可靠数据" : stats.samplingDescription)
        ]
    }
}

struct PhotoMetadata: Codable, Equatable {
    var width = 0
    var height = 0
    var fileSize: Int64 = 0
    var format = ""
    var camera = ""
    var lens = ""
    var focalLength = ""
    var focalLength35 = ""
    var aperture = ""
    var shutter = ""
    var iso = ""
    var exposureBias = ""
    var exposureProgram = ""
    var exposureMode = ""
    var meteringMode = ""
    var flash = ""
    var whiteBalance = ""
    var lightSource = ""
    var sceneCaptureType = ""
    var brightnessValue = ""
    var digitalZoom = ""
    var subjectDistance = ""
    var maxAperture = ""
    var contrast = ""
    var saturation = ""
    var sharpness = ""
    var captureDate = ""
    var digitizedDate = ""
    var subsecondTime = ""
    var timeZone = ""
    var gpsLatitude = ""
    var gpsLongitude = ""
    var gpsAltitude = ""
    var colorProfile = ""
    var orientation = ""
    var software = ""
    var artist = ""
    var copyright = ""
    var title = ""
    var caption = ""
    var keywords = ""
    var rating = ""
    var colorLabel = ""
    var extendedFields: [MetadataField] = []
    var hdr = HDRInfo()
    var gainMap = GainMapInfo.none

    private func nonEmpty(_ rows: [(String, String)]) -> [(String, String)] {
        rows.filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var sections: [(String, [(String, String)])] {
        [
            ("文件与图像", nonEmpty([
                ("尺寸", "\(width) × \(height)"),
                ("文件大小", ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)),
                ("格式", format), ("方向", orientation)
            ])),
            ("拍摄参数", nonEmpty([
                ("相机", camera), ("镜头", lens), ("焦距", focalLength),
                ("35mm 等效", focalLength35), ("光圈", aperture), ("快门", shutter),
                ("ISO", iso), ("曝光补偿", exposureBias), ("曝光程序", exposureProgram),
                ("曝光模式", exposureMode), ("测光模式", meteringMode), ("闪光灯", flash),
                ("白平衡", whiteBalance), ("光源", lightSource),
                ("场景模式", sceneCaptureType), ("数码变焦", digitalZoom),
                ("被摄体距离", subjectDistance), ("最大光圈", maxAperture),
                ("对比度", contrast), ("饱和度", saturation), ("锐度", sharpness)
            ])),
            ("时间与位置", nonEmpty([
                ("原始拍摄时间", captureDate), ("数字化时间", digitizedDate),
                ("毫秒时间", subsecondTime), ("时区", timeZone),
                ("GPS 纬度", gpsLatitude), ("GPS 经度", gpsLongitude),
                ("GPS 海拔", gpsAltitude), ("场景亮度 EV", brightnessValue)
            ])),
            ("色彩与动态范围", nonEmpty([
                ("主图 / Base 色彩空间", gainMap.available && !gainMap.baseColorSpace.isEmpty ? gainMap.baseColorSpace : colorProfile),
                ("HDR Alternate 色彩空间", gainMap.available ? (gainMap.alternateColorSpace.isEmpty ? "未单独声明" : gainMap.alternateColorSpace) : ""),
                ("Base 传递函数", gainMap.available ? gainMap.baseTransferFunction : ""),
                ("HDR 传递函数", gainMap.available ? gainMap.alternateTransferFunction : hdr.transfer),
                ("色彩描述（ICC）", colorProfile), ("软件", software),
                ("动态范围", hdr.kind), ("色域（Base）", hdr.gamut),
                ("位深", "\(hdr.bitDepth) bit"),
                ("MaxCLL", hdr.maxCLL.map { String(format: "%.0f nit", $0) } ?? ""),
                ("MaxFALL", hdr.maxFALL.map { String(format: "%.0f nit", $0) } ?? ""),
                ("HDR 识别置信度", hdr.confidence),
                ("Gain Map", gainMap.available ? gainMap.kind : "无")
            ])),
            ("描述与版权", nonEmpty([
                ("作者", artist), ("版权", copyright), ("标题", title),
                ("说明", caption), ("关键词", keywords), ("评分", rating),
                ("颜色标签", colorLabel)
            ])),
            ("扩展元数据", extendedFields.map { ($0.key, "\($0.value) [\($0.source)]") })
        ].filter { !$0.1.isEmpty }
    }

    var rows: [(String, String)] {
        sections.flatMap { $0.1 }
    }
}

@MainActor
final class PhotoItem: ObservableObject, Identifiable, @MainActor Hashable {
    nonisolated let id: UUID
    let url: URL
    let addedIndex: Int
    @Published var thumbnail: NSImage?
    var thumbnailCGImage: CGImage?
    @Published var preview: CGImage?
    @Published var displayPreview: CGImage?
    // Keep both decoded display renditions so toggling HDR/SDR reuses the
    // already decoded image instead of decoding the source again.
    var hdrPreview: CGImage?
    var sdrPreview: CGImage?
    // HDR effect metrics are source-driven for Gain Map files. Keep the
    // analysis image separate from the system-rendered preview so face and
    // effect analysis never silently falls back to a display rendition.
    var hdrAnalysisImage: CGImage?
    var sdrAnalysisImage: CGImage?
    var hdrHistogram: HistogramData?
    var sdrHistogram: HistogramData?
    var hdrAnalysis: ImageAnalysisData?
    var sdrAnalysis: ImageAnalysisData?
    var previewGeneration = 0
    var previewLoadingMode: HDRMode?
    @Published var metadata = PhotoMetadata()
    @Published var histogram = HistogramData.empty
    @Published var analysis = ImageAnalysisData.empty
    @Published var loading = false
    @Published var faceAnalysisLoading = false
    @Published var analysisLoadingModes: Set<HDRMode> = []
    @Published var error: String?
    @Published var rating = 0
    @Published var favorite = false
    @Published var colorLabel = ""
    @Published var alignment = CGAffineTransform.identity
    @Published var alignmentConfidence: Double?

    init(id: UUID = UUID(), url: URL, addedIndex: Int) {
        self.id = id
        self.url = url
        self.addedIndex = addedIndex
    }
    func cachedPreview(for mode: HDRMode) -> CGImage? {
        mode == .sdr ? sdrPreview : hdrPreview
    }
    func cachedHistogram(for mode: HDRMode) -> HistogramData? {
        mode == .sdr ? sdrHistogram : hdrHistogram
    }
    func cachedAnalysis(for mode: HDRMode) -> ImageAnalysisData? {
        mode == .sdr ? sdrAnalysis : hdrAnalysis
    }
    func cachedAnalysisImage(for mode: HDRMode) -> CGImage? {
        mode == .sdr ? sdrAnalysisImage : hdrAnalysisImage
    }
    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ProjectDocument: Codable {
    var paths: [String]
    var selection: [String]
    var mode: AppMode
    var hdrMode: HDRMode
    var theme: AppTheme
    var ratings: [String: Int]
    var favorites: [String: Bool]
    var labels: [String: String]
}
