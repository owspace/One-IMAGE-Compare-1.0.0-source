import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ImageAnalysisResult {
    var histogram: HistogramData
    var analysis: ImageAnalysisData
}

struct ImageLoadResult {
    var displayImage: CGImage
    var analysisImage: CGImage
    var metadata: PhotoMetadata
    var histogram: HistogramData
    var analysis: ImageAnalysisData
}

enum ImagePipeline {
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng", "avif",
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2",
        "pef", "raw", "rwl", "3fr", "fff", "iiq"
    ]
    private static let context = CIContext(options: [
        .cacheIntermediates: true,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any
    ])

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func load(url: URL, maxPixel: Int, sdr: Bool) throws -> ImageLoadResult {
        let options: CFDictionary = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            throw NSError(domain: "OneImageCompare", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取图像"])
        }
        var metadata = readMetadata(source: source, url: url)
        let thumbOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true,
            kCGImageSourceDecodeRequest: sdr ? kCGImageSourceDecodeToSDR : kCGImageSourceDecodeToHDR
        ] as CFDictionary
        var image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions)
        if image == nil, let raw = CIRAWFilter(imageURL: url) {
            raw.isDraftModeEnabled = maxPixel <= 800
            raw.scaleFactor = min(1, Float(maxPixel) / Float(max(metadata.width, metadata.height)))
            raw.extendedDynamicRangeAmount = sdr ? 0 : 1
            if let output = raw.outputImage {
                image = context.createCGImage(output, from: output.extent)
            }
        }
        guard let displayImage = image else {
            throw NSError(domain: "OneImageCompare", code: 2, userInfo: [NSLocalizedDescriptionKey: "系统不支持此 RAW/图像格式"])
        }

        var analysisImage = displayImage
        var measurementBasis = sdr ? "SDR 基础图像素" : "系统 DecodeToHDR（显示预览）"
        var sourceDriven = false
        var measured: ImageAnalysisResult
        if !sdr, metadata.gainMap.available,
           let reconstruction = reconstructGainMap(source: source, url: url, metadata: metadata,
                                                   maxPixel: min(maxPixel, 1024)) {
            metadata.gainMap.sourceStats = reconstruction.stats
            if let reconstructedImage = reconstruction.image {
                analysisImage = reconstructedImage
            }
            measured = analyze(buffer: reconstruction.buffer, domain: .hdr)
            measurementBasis = "Base + 原始 Gain Map 的 ISO 21496-1 受控重建"
            sourceDriven = true
        } else if !sdr, metadata.gainMap.available {
            measured = analyze(image: analysisImage, domain: .hdr)
            measurementBasis = "系统 DecodeToHDR 回退（无法读取原始 Gain Map）"
        } else {
            measured = analyze(image: analysisImage, domain: sdr ? .sdr : .hdr)
        }

        measured.analysis.measurementBasis = measurementBasis
        measured.analysis.sourceDriven = sourceDriven
        measured.histogram.contentHeadroomEV = metadata.hdr.headroom.map { max(0, log2(max(1, $0))) }
            ?? metadata.gainMap.alternateHDRHeadroom.map { max(0, $0) }
        return ImageLoadResult(displayImage: displayImage, analysisImage: analysisImage,
                               metadata: metadata, histogram: measured.histogram,
                               analysis: measured.analysis)
    }

    static func readMetadata(source: CGImageSource, url: URL) -> PhotoMetadata {
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let profile = props[kCGImagePropertyProfileName] as? String ?? ""
        let depth = numberValue(props[kCGImagePropertyDepth]).map { Int($0.rounded()) } ?? 8
        var values: [String: Any] = [:]
        collectDictionary(exif as NSDictionary, into: &values, prefix: "EXIF")
        collectDictionary(tiff as NSDictionary, into: &values, prefix: "TIFF")
        collectDictionary(gps as NSDictionary, into: &values, prefix: "GPS")
        collectDictionary(props as NSDictionary, into: &values)
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            collectMetadata(metadata, into: &values)
        }

        var m = PhotoMetadata()
        m.width = numberValue(props[kCGImagePropertyPixelWidth]).map { Int($0.rounded()) } ?? 0
        m.height = numberValue(props[kCGImagePropertyPixelHeight]).map { Int($0.rounded()) } ?? 0
        m.fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        m.format = url.pathExtension.uppercased()
        m.camera = [stringValue(named: ["Make"], in: values), stringValue(named: ["Model"], in: values)]
            .compactMap { $0 }.joined(separator: " ")
        m.lens = stringValue(named: ["LensModel", "LensSpecification"], in: values) ?? ""
        if let f = numberValue(firstValue(["FocalLength"], in: values)) { m.focalLength = String(format: "%.1f mm", f) }
        if let f = numberValue(firstValue(["FocalLenIn35mmFilm", "FocalLengthIn35mmFilm"], in: values)) {
            m.focalLength35 = String(format: "%.0f mm", f)
        }
        if let f = numberValue(firstValue(["FNumber"], in: values)) { m.aperture = String(format: "f/%.1f", f) }
        if let t = numberValue(firstValue(["ExposureTime"], in: values)) {
            m.shutter = t >= 1 ? String(format: "%.2f s", t) : "1/\(max(1, Int((1 / t).rounded()))) s"
        }
        let isoValue = firstValue(["PhotographicSensitivity", "ExifPhotographicSensitivity", "ISOSpeedRatings", "ExifISOSpeedRatings",
                                   "ExifPhotographicSensitivity", "ISO"], in: values)
        m.iso = numberValue(isoValue).map { String(Int($0.rounded())) } ?? stringArrayValue(isoValue)
        if let e = numberValue(firstValue(["ExposureBiasValue", "ExposureCompensation"], in: values)) {
            m.exposureBias = String(format: "%+.2f EV", e)
        }
        m.exposureProgram = enumValue(firstValue(["ExposureProgram"], in: values), values: [
            0: "未定义", 1: "手动", 2: "程序自动", 3: "光圈优先", 4: "快门优先",
            5: "创意程序", 6: "运动程序", 7: "人像", 8: "风景"
        ])
        m.exposureMode = enumValue(firstValue(["ExposureMode"], in: values), values: [0: "自动", 1: "手动", 2: "自动包围曝光"])
        m.meteringMode = enumValue(firstValue(["MeteringMode"], in: values), values: [
            0: "未知", 1: "平均", 2: "中央重点", 3: "点测光", 4: "多点", 5: "模式",
            6: "局部", 255: "其他"
        ])
        m.flash = flashValue(firstValue(["Flash"], in: values))
        m.whiteBalance = enumValue(firstValue(["WhiteBalance"], in: values), values: [0: "自动", 1: "手动"])
        m.lightSource = enumValue(firstValue(["LightSource"], in: values), values: [
            0: "未知", 1: "日光", 2: "荧光灯", 3: "钨丝灯", 4: "闪光灯", 9: "晴天",
            10: "阴天", 11: "阴影", 12: "日光荧光灯", 13: "白色荧光灯", 14: "冷白荧光灯",
            15: "白天荧光灯", 17: "标准光 A", 18: "标准光 B", 19: "标准光 C", 20: "D55",
            21: "D65", 22: "D75", 23: "D50", 24: "ISO 摄影灯", 255: "其他"
        ])
        m.sceneCaptureType = enumValue(firstValue(["SceneCaptureType"], in: values), values: [0: "标准", 1: "风景", 2: "人像", 3: "夜景"])
        m.brightnessValue = numberValue(firstValue(["BrightnessValue"], in: values)).map { String(format: "%.2f EV", $0) } ?? ""
        m.digitalZoom = numberValue(firstValue(["DigitalZoomRatio"], in: values)).map { String(format: "%.2f×", $0) } ?? ""
        m.subjectDistance = numberValue(firstValue(["SubjectDistance"], in: values)).map { String(format: "%.2f m", $0) } ?? ""
        m.maxAperture = numberValue(firstValue(["MaxApertureValue"], in: values)).map { String(format: "%.2f EV", $0) } ?? ""
        m.contrast = enumValue(firstValue(["Contrast"], in: values), values: [0: "标准", 1: "柔和", 2: "硬调"])
        m.saturation = enumValue(firstValue(["Saturation"], in: values), values: [0: "标准", 1: "低饱和", 2: "高饱和"])
        m.sharpness = enumValue(firstValue(["Sharpness"], in: values), values: [0: "标准", 1: "柔和", 2: "锐利"])
        m.captureDate = stringValue(named: ["DateTimeOriginal", "DateTime"], in: values) ?? ""
        m.digitizedDate = stringValue(named: ["DateTimeDigitized"], in: values) ?? ""
        m.subsecondTime = stringValue(named: ["SubsecTimeOriginal"], in: values) ?? ""
        m.timeZone = stringValue(named: ["OffsetTimeOriginal", "TimeZoneOffset"], in: values) ?? ""
        m.gpsLatitude = gpsCoordinate(latitude: true, in: gps)
        m.gpsLongitude = gpsCoordinate(latitude: false, in: gps)
        m.gpsAltitude = numberValue(named: ["Altitude"], in: gps).map { String(format: "%.1f m", $0) } ?? ""
        m.colorProfile = profile
        m.orientation = String(describing: props[kCGImagePropertyOrientation] ?? "")
        m.software = stringValue(named: ["Software"], in: values) ?? ""
        m.artist = stringValue(named: ["Artist", "Byline"], in: values) ?? ""
        m.copyright = stringValue(named: ["Copyright", "CopyrightNotice"], in: values) ?? ""
        m.title = stringValue(named: ["Title", "Headline"], in: values) ?? ""
        m.caption = stringValue(named: ["Description", "CaptionAbstract", "ImageDescription"], in: values) ?? ""
        m.keywords = stringArrayValue(firstValue(["Keywords", "Subject"], in: values))
        m.rating = stringValue(named: ["Rating"], in: values) ?? ""
        m.colorLabel = stringValue(named: ["Label", "ColorLabel"], in: values) ?? ""
        m.gainMap = readGainMapInfo(source: source, primaryWidth: m.width, primaryHeight: m.height,
                                    baseColorSpace: profile)

        var hdr = HDRInfo()
        hdr.bitDepth = depth
        hdr.gamut = gamutDescription(for: profile)
        let propertyDump = String(describing: props).lowercased()
        if m.gainMap.available {
            let alternateTransfer = m.gainMap.alternateTransferFunction.isEmpty
                ? "未单独声明" : m.gainMap.alternateTransferFunction
            hdr.kind = "HDR · \(m.gainMap.kind)"
            hdr.transfer = "Base \(m.gainMap.baseTransferFunction) → HDR \(alternateTransfer)"
            hdr.confidence = "高"
            hdr.evidence.append("检测到 \(m.gainMap.kind) 辅助图")
        } else if propertyDump.contains("2084") || propertyDump.contains("pq") {
            hdr.kind = "HDR · PQ"; hdr.transfer = "ST 2084 (PQ)"; hdr.confidence = "高"
            hdr.evidence.append("元数据包含 PQ/ST 2084")
        } else if propertyDump.contains("hlg") || propertyDump.contains("arib") {
            hdr.kind = "HDR · HLG"; hdr.transfer = "HLG"; hdr.confidence = "高"
            hdr.evidence.append("元数据包含 HLG")
        } else if depth > 8 && (hdr.gamut == "BT.2020" || propertyDump.contains("hdr")) {
            hdr.kind = "HDR · 未明确类型"; hdr.transfer = "未明确"; hdr.confidence = "中"
            hdr.evidence.append("高位深与广色域/HDR 标记")
        } else {
            hdr.kind = "SDR"; hdr.transfer = "SDR Gamma"; hdr.confidence = "高"
        }
        if let headroom = numericValue(in: props, matching: ["headroom", "hdrheadroom"]) { hdr.headroom = headroom }
        if let cll = numericValue(in: props, matching: ["maxcll", "contentlightlevel"]) { hdr.maxCLL = cll }
        if let fall = numericValue(in: props, matching: ["maxfall", "frameaveragelightlevel"]) { hdr.maxFALL = fall }
        let known = Set(["make", "model", "lensmodel", "focallength", "fnumber", "exposuretime",
                         "isospeedratings", "photographicsensitivity", "exposurebiasvalue", "exposureprogram",
                         "exposuremode", "meteringmode", "flash", "whitebalance", "lightsource",
                         "scenecapturetype", "brightnessvalue", "digitalzoomratio", "subjectdistance",
                         "maxaperturevalue", "contrast", "saturation", "sharpness", "datetimeoriginal",
                         "datetimedigitized", "subsectimeoriginal", "offsettimeoriginal", "timezoneoffset",
                         "altitude", "latitude", "longitude", "software", "artist", "copyright",
                         "copyrightnotice", "title", "headline", "description", "captionabstract",
                         "imagedescription", "keywords", "subject", "rating", "label", "colorlabel"])
        m.extendedFields = values.compactMap { key, value in
            let normalized = normalizeKey(key)
            guard !known.contains(normalized), !normalized.contains("channelmetadata"),
                  let string = stringValue(value), !string.isEmpty, string.count < 300 else { return nil }
            return MetadataField(key: key, value: string, source: key.contains(":") ? "ImageIO metadata" : "ImageIO")
        }.sorted { $0.key < $1.key }.prefix(80).map { $0 }
        m.hdr = hdr
        return m
    }

    private static func gamutDescription(for profile: String) -> String {
        let lower = profile.lowercased()
        if lower.contains("2020") || lower.contains("bt.2100") || lower.contains("itur_2100") {
            return "BT.2020"
        }
        if lower.contains("dci-p3") { return "DCI-P3" }
        if lower.contains("p3") { return "Display P3" }
        if lower.contains("srgb") { return "sRGB" }
        return profile.isEmpty ? "未知" : profile
    }

    private static func gainMapAuxiliaryInfo(source: CGImageSource) -> (dictionary: NSDictionary, isISO: Bool)? {
        if #available(macOS 15.0, *),
           let isoInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) {
            return (isoInfo as NSDictionary, true)
        }
        if let appleInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) {
            return (appleInfo as NSDictionary, false)
        }
        return nil
    }

    private static func readGainMapInfo(source: CGImageSource, primaryWidth: Int, primaryHeight: Int,
                                        baseColorSpace: String) -> GainMapInfo {
        guard let resolved = gainMapAuxiliaryInfo(source: source) else { return .none }

        let auxiliary = resolved.dictionary
        let description = auxiliary.object(forKey: kCGImageAuxiliaryDataInfoDataDescription) as? NSDictionary
        let metadata: CGImageMetadata?
        if auxiliary.object(forKey: kCGImageAuxiliaryDataInfoMetadata) != nil {
            metadata = (auxiliary.object(forKey: kCGImageAuxiliaryDataInfoMetadata) as! CGImageMetadata)
        } else {
            metadata = nil
        }
        var values: [String: Any] = [:]
        if let description { collectDictionary(description, into: &values) }
        if let metadata { collectMetadata(metadata, into: &values) }

        var result = GainMapInfo()
        result.available = true
        result.kind = resolved.isISO ? "ISO 21496-1" : "Apple HDR Gain Map"
        result.primaryWidth = primaryWidth
        result.primaryHeight = primaryHeight
        result.resolutionWidth = intValue(firstValue(["Width", "MapWidth", "GainMapWidth"], in: values)) ?? 0
        result.resolutionHeight = intValue(firstValue(["Height", "MapHeight", "GainMapHeight"], in: values)) ?? 0
        if let rawPixelFormat = numberValue(firstValue(["PixelFormat"], in: values)) {
            result.pixelFormat = pixelFormatDescription(Int(rawPixelFormat.rounded()))
        }
        result.minimumVersion = stringValue(firstValue(["MinimumVersion", "MinVersion", "Version"], in: values))
        result.writerVersion = stringValue(firstValue(["WriterVersion"], in: values))
        result.multichannel = boolValue(firstValue(["Multichannel", "MultiChannel", "IsMultiChannel"], in: values))
        result.useBaseColorSpace = boolValue(firstValue(["UseBaseColorSpace", "UseBaseColourSpace", "BaseColorIsWorkingColor"], in: values))
        result.baseHDRHeadroom = doubleValues(firstValue(["BaseHDRHeadroom", "BaseHeadroom", "HDRCapacityMin"], in: values)).first
        result.alternateHDRHeadroom = doubleValues(firstValue(["AlternateHDRHeadroom", "AltHDRHeadroom", "AlternateHeadroom", "HDRCapacityMax"], in: values)).first
        result.baseColorSpace = displayColorSpaceDescription(
            stringValue(firstValue(["BaseColorSpace", "BaseColourSpace"], in: values)) ?? baseColorSpace
        )
        result.baseTransferFunction = transferFunction(for: result.baseColorSpace, base: true)
        result.alternateColorSpace = displayColorSpaceDescription(
            stringValue(firstValue(["AlternateColorSpace", "AlternateColourSpace"], in: values)) ?? ""
        )
        if result.alternateColorSpace.isEmpty, #available(macOS 15.0, *),
           let colorSpaceObject = auxiliary.object(forKey: kCGImageAuxiliaryDataInfoColorSpace) {
            let colorSpace = colorSpaceObject as! CGColorSpace
            result.alternateColorSpace = displayColorSpaceDescription(colorSpace)
        }
        result.alternateTransferFunction = transferFunction(for: result.alternateColorSpace, base: false)
        result.gainMapMin = doubleValues(firstValue(["GainMapMin", "MapMin"], in: values))
        result.gainMapMax = doubleValues(firstValue(["GainMapMax", "MapMax"], in: values))
        result.gamma = doubleValues(firstValue(["Gamma"], in: values))
        result.baseOffset = doubleValues(firstValue(["BaseOffset", "OffsetSDR"], in: values))
        result.alternateOffset = doubleValues(firstValue(["AlternateOffset", "OffsetHDR"], in: values))

        if result.multichannel == nil {
            let channelCount = max(result.gainMapMin.count, result.gainMapMax.count, result.gamma.count,
                                   result.baseOffset.count, result.alternateOffset.count)
            if channelCount > 1 { result.multichannel = true }
            else if let pixelFormat = stringValue(firstValue(["PixelFormat"], in: values)) {
                result.multichannel = pixelFormat.localizedCaseInsensitiveContains("rgb") &&
                    !pixelFormat.localizedCaseInsensitiveContains("gray")
            }
        }
        return result
    }

    private struct GainMapReconstruction {
        var image: CGImage?
        var buffer: LinearBuffer
        var stats: GainMapSourceStats
    }

    /// Reconstruct the alternate image from the file's baseline image and
    /// auxiliary gain-map pixels. This is deliberately separate from
    /// ImageIO's DecodeToHDR request: the latter remains the display preview,
    /// while this path is the source of truth for content analysis.
    private static func reconstructGainMap(source: CGImageSource, url: URL, metadata: PhotoMetadata,
                                           maxPixel: Int) -> GainMapReconstruction? {
        guard let resolved = gainMapAuxiliaryInfo(source: source) else { return nil }
        let mapData: Data? = {
            guard let rawDataObject = resolved.dictionary.object(forKey: kCGImageAuxiliaryDataInfoData) else { return nil }
            return (rawDataObject as? Data) ?? (rawDataObject as? NSData).map { $0 as Data }
        }()

        let targetMaxPixel = max(256, min(maxPixel, 1024))
        let baseOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxPixel,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR
        ] as CFDictionary
        guard let baseImage = CGImageSourceCreateThumbnailAtIndex(source, 0, baseOptions),
              let baseBuffer = renderLinearBuffer(baseImage, maximumDimension: targetMaxPixel),
              let mapBuffer = gainMapBuffer(url: url, resolved: resolved, data: mapData,
                                            width: baseBuffer.width, height: baseBuffer.height) else { return nil }

        let mapInfo = metadata.gainMap
        let multichannel = mapInfo.multichannel == true ||
            max(mapInfo.gainMapMin.count,
                max(mapInfo.gainMapMax.count,
                    max(mapInfo.gamma.count,
                        max(mapInfo.baseOffset.count, mapInfo.alternateOffset.count)))) > 1
        let channelCount = multichannel ? 3 : 1
        let baseWidth = baseBuffer.width
        let baseHeight = baseBuffer.height
        var output = [Float](repeating: 0, count: baseWidth * baseHeight * 4)
        var encodedSamples: [Double] = []
        var gainSamples: [Double] = []
        var liftSamples: [Double] = []
        encodedSamples.reserveCapacity(baseWidth * baseHeight)
        gainSamples.reserveCapacity(baseWidth * baseHeight)
        liftSamples.reserveCapacity(baseWidth * baseHeight)

        var validCount = 0
        var activeCount = 0
        let coefficients = (0.2289746, 0.6917385, 0.0792869)

        for y in 0..<baseHeight {
            for x in 0..<baseWidth {
                let pixel = y * baseWidth + x
                let baseOffset = pixel * 4
                let mapOffset = baseOffset
                let alpha = max(0, min(1, baseBuffer.float(at: baseOffset + 3)))
                guard alpha > 0.001 else { continue }

                var baseR = baseBuffer.float(at: baseOffset)
                var baseG = baseBuffer.float(at: baseOffset + 1)
                var baseB = baseBuffer.float(at: baseOffset + 2)
                if alpha < 0.999 {
                    baseR /= alpha; baseG /= alpha; baseB /= alpha
                }
                if !baseBuffer.isLinear {
                    baseR = sRGBToLinear(baseR)
                    baseG = sRGBToLinear(baseG)
                    baseB = sRGBToLinear(baseB)
                }

                let encoded = [
                    mapBuffer.value(at: mapOffset),
                    mapBuffer.value(at: mapOffset + 1),
                    mapBuffer.value(at: mapOffset + 2)
                ]
                let componentGain: (Int) -> Double = { channel in
                    let sourceChannel = channelCount == 1 ? encoded[0] : encoded[channel]
                    let gamma = max(0.000001, self.component(mapInfo.gamma, index: channel, fallback: 1))
                    let normalized = pow(min(1, max(0, sourceChannel)), 1 / gamma)
                    let minimum = self.component(mapInfo.gainMapMin, index: channel, fallback: 0)
                    let maximum = self.component(mapInfo.gainMapMax, index: channel, fallback: minimum)
                    return minimum + (maximum - minimum) * normalized
                }
                let gainR = componentGain(0)
                let gainG = componentGain(1)
                let gainB = componentGain(2)
                let baseOffsetR = component(mapInfo.baseOffset, index: 0, fallback: 0)
                let baseOffsetG = component(mapInfo.baseOffset, index: 1, fallback: baseOffsetR)
                let baseOffsetB = component(mapInfo.baseOffset, index: 2, fallback: baseOffsetR)
                let alternateOffsetR = component(mapInfo.alternateOffset, index: 0, fallback: 0)
                let alternateOffsetG = component(mapInfo.alternateOffset, index: 1, fallback: alternateOffsetR)
                let alternateOffsetB = component(mapInfo.alternateOffset, index: 2, fallback: alternateOffsetR)

                let alternateR = max(0, (baseR + baseOffsetR) * pow(2, gainR) - alternateOffsetR)
                let alternateG = max(0, (baseG + baseOffsetG) * pow(2, gainG) - alternateOffsetG)
                let alternateB = max(0, (baseB + baseOffsetB) * pow(2, gainB) - alternateOffsetB)
                output[baseOffset] = Float(alternateR)
                output[baseOffset + 1] = Float(alternateG)
                output[baseOffset + 2] = Float(alternateB)
                output[baseOffset + 3] = Float(alpha)

                let encodedMean = channelCount == 1
                    ? encoded[0] : (encoded[0] + encoded[1] + encoded[2]) / 3
                let gainMean = (gainR + gainG + gainB) / 3
                encodedSamples.append(encodedMean)
                gainSamples.append(gainMean)
                validCount += 1
                if abs(gainMean) > 0.0001 { activeCount += 1 }

                let baseLuma = max(0, coefficients.0 * baseR + coefficients.1 * baseG + coefficients.2 * baseB)
                let alternateLuma = max(0, coefficients.0 * alternateR + coefficients.1 * alternateG + coefficients.2 * alternateB)
                if baseLuma > 0.000001, alternateLuma > 0.000001 {
                    liftSamples.append(log2(alternateLuma / baseLuma))
                }
            }
        }

        guard validCount > 0 else { return nil }
        let sortedEncoded = encodedSamples.sorted()
        let sortedGain = gainSamples.sorted()
        let sortedLift = liftSamples.sorted()
        var stats = GainMapSourceStats()
        stats.available = true
        stats.sampleCount = baseWidth * baseHeight
        stats.validSampleCount = validCount
        stats.encodedMean = encodedSamples.reduce(0, +) / Double(encodedSamples.count)
        stats.encodedP01 = percentile(sortedEncoded, 0.01)
        stats.encodedP50 = percentile(sortedEncoded, 0.50)
        stats.encodedP99 = percentile(sortedEncoded, 0.99)
        stats.gainEVMean = gainSamples.reduce(0, +) / Double(gainSamples.count)
        stats.gainEVP01 = percentile(sortedGain, 0.01)
        stats.gainEVP50 = percentile(sortedGain, 0.50)
        stats.gainEVP99 = percentile(sortedGain, 0.99)
        stats.gainEVMin = sortedGain.first
        stats.gainEVMax = sortedGain.last
        stats.reconstructedLiftEVMean = sortedLift.isEmpty ? nil : sortedLift.reduce(0, +) / Double(sortedLift.count)
        stats.reconstructedLiftEVP95 = percentile(sortedLift, 0.95)
        stats.activeRatio = Double(activeCount) / Double(validCount)
        stats.samplingDescription = "原始辅助图，\(baseWidth) × \(baseHeight) 对齐采样"

        let buffer = LinearBuffer(data: Data(bytes: output, count: output.count * MemoryLayout<Float>.size),
                                  width: baseWidth, height: baseHeight, isLinear: true,
                                  samplingDescription: "ISO 21496-1 源数据重建")
        return GainMapReconstruction(image: makeImage(from: buffer), buffer: buffer, stats: stats)
    }

    private static func gainMapBuffer(url: URL,
                                      resolved: (dictionary: NSDictionary, isISO: Bool),
                                      data: Data?, width: Int, height: Int) -> EncodedBuffer? {
        if let data,
           let mapSource = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true
        ] as CFDictionary),
           let mapImage = CGImageSourceCreateImageAtIndex(mapSource, 0, [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true
           ] as CFDictionary) {
            return renderNormalizedBuffer(mapImage, width: width, height: height)
        }

        if let data,
           let description = resolved.dictionary.object(forKey: kCGImageAuxiliaryDataInfoDataDescription) as? NSDictionary,
           let mapImage = makeAuxiliaryCGImage(data: data, description: description),
           let buffer = renderNormalizedBuffer(mapImage, width: width, height: height) {
            return buffer
        }

        // ImageIO may expose only the Gain Map description/metadata for
        // Y'CbCr auxiliary formats such as 444f and 420f. Core Image's
        // public auxiliaryHDRGainMap option still returns the decoded
        // monochrome Gain Map, preserving a source-driven path without
        // treating the system HDR preview as the measurement source.
        guard let auxiliary = CIImage(contentsOf: url, options: [.auxiliaryHDRGainMap: true]),
              let mapImage = context.createCGImage(auxiliary, from: auxiliary.extent) else { return nil }
        return renderNormalizedBuffer(mapImage, width: width, height: height)
    }

    /// ImageIO exposes some Gain Maps as raw CVPixelBuffer bytes rather than
    /// an encoded image. The description tells us how to wrap that buffer as a
    /// CGImage without changing the stored normalized map values.
    private static func makeAuxiliaryCGImage(data: Data, description: NSDictionary) -> CGImage? {
        let width = intValue(description.object(forKey: "Width") ?? description.object(forKey: kCGImagePropertyWidth)) ?? 0
        let height = intValue(description.object(forKey: "Height") ?? description.object(forKey: kCGImagePropertyHeight)) ?? 0
        let bytesPerRow = intValue(description.object(forKey: "BytesPerRow") ?? description.object(forKey: kCGImagePropertyBytesPerRow)) ?? 0
        let pixelFormat = intValue(description.object(forKey: "PixelFormat") ?? description.object(forKey: kCGImagePropertyPixelFormat)) ?? 0
        guard width > 0, height > 0, bytesPerRow > 0,
              data.count >= bytesPerRow * height else { return nil }

        let l008 = pixelFormatCode("L008")
        let l016 = pixelFormatCode("L016")
        let bitsPerComponent: Int
        let bitsPerPixel: Int
        switch pixelFormat {
        case l008:
            bitsPerComponent = 8
            bitsPerPixel = 8
        case l016:
            bitsPerComponent = 16
            bitsPerPixel = 16
        default:
            return nil
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: bitsPerComponent,
                       bitsPerPixel: bitsPerPixel,
                       bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func pixelFormatCode(_ value: String) -> Int {
        value.utf8.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func pixelFormatDescription(_ value: Int) -> String {
        let fourCC = String(decoding: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ], as: UTF8.self)
        switch fourCC {
        case "L008": return "L008（单通道 8-bit）"
        case "L016": return "L016（单通道 16-bit）"
        case "444f": return "444f（YCbCr 8-bit 4:4:4，全范围双平面）"
        case "420f": return "420f（YCbCr 8-bit 4:2:0，全范围双平面）"
        default:
            return fourCC.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0.value <= 0x7e }
                ? "\(fourCC)（FourCC）"
                : String(format: "0x%08X", value)
        }
    }

    private static func component(_ values: [Double], index: Int, fallback: Double) -> Double {
        guard !values.isEmpty else { return fallback }
        if values.count == 1 { return values[0] }
        return index < values.count ? values[index] : values[values.count - 1]
    }

    private static func displayColorSpaceDescription(_ colorSpace: CGColorSpace) -> String {
        if let name = colorSpace.name as String? {
            return displayColorSpaceDescription(name)
        }
        return displayColorSpaceDescription(String(describing: colorSpace))
    }

    private static func displayColorSpaceDescription(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        let lower = value.lowercased()
        let hasPQ = lower.contains("pq") || lower.contains("2084") || lower.contains("st 2084")
        let hasHLG = lower.contains("hlg") || lower.contains("arib")
        let hasP3 = lower.contains("display p3") || lower.contains("displayp3") ||
            lower.contains("p3 primaries") || lower.contains("dci-p3")

        if lower.contains("itur_2100_pq") || lower.contains("bt.2100 pq") {
            return "Rec. ITU-R BT.2100 PQ"
        }
        if lower.contains("itur_2100_hlg") || lower.contains("bt.2100 hlg") {
            return "Rec. ITU-R BT.2100 HLG"
        }
        if hasP3 && hasPQ {
            return lower.contains("adaptive gain curve")
                ? "Display P3 + PQ（Adaptive Gain Curve）"
                : "Display P3 + PQ"
        }
        if lower.contains("srgb eotf") && lower.contains("dci-p3") {
            return "DCI-P3 色域 + sRGB EOTF"
        }
        if lower == "kcgcolorspacedisplayp3" || lower.contains("kcgcolorspacedisplayp3") {
            return "Display P3"
        }
        if lower == "kcgcolorspacesrgb" || lower.contains("kcgcolorspacesrgb") {
            return "sRGB"
        }
        if hasHLG { return "HLG" }
        if hasPQ { return "PQ" }
        return value
    }

    private static func transferFunction(for description: String, base: Bool) -> String {
        let lower = description.lowercased()
        if lower.contains("pq") || lower.contains("2084") || lower.contains("st 2084") {
            return "PQ / SMPTE ST 2084"
        }
        if lower.contains("hlg") || lower.contains("arib") {
            return "HLG / ARIB STD-B67"
        }
        if lower.contains("srgb eotf") {
            return "sRGB EOTF"
        }
        if lower.contains("linear") {
            return "Linear"
        }
        if lower.contains("display p3") || lower.contains("srgb") || lower.contains("gamma") {
            return "SDR Gamma（sRGB-like）"
        }
        return base ? "SDR（未明确）" : ""
    }

    private static func normalizeKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func collectDictionary(_ dictionary: NSDictionary, into values: inout [String: Any], prefix: String = "") {
        for key in dictionary.allKeys {
            guard let child = dictionary.object(forKey: key) else { continue }
            if child is Data { continue }
            let name = String(describing: key)
            let path = prefix.isEmpty ? name : "\(prefix).\(name)"
            values[normalizeKey(name)] = child
            values[normalizeKey(path)] = child
            if let nested = child as? NSDictionary {
                collectDictionary(nested, into: &values, prefix: path)
            } else if let array = child as? NSArray {
                for (index, value) in array.enumerated() {
                    if let nested = value as? NSDictionary {
                        collectDictionary(nested, into: &values, prefix: "\(path)[\(index)]")
                    }
                }
            }
        }
    }

    private static func collectMetadata(_ metadata: CGImageMetadata, into values: inout [String: Any]) {
        guard let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return }
        for tag in tags {
            let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            guard let value = CGImageMetadataTagCopyValue(tag) else { continue }
            let path = prefix.isEmpty ? name : "\(prefix):\(name)"
            values[normalizeKey(name)] = value
            values[normalizeKey(path)] = value
            if let nested = value as? NSDictionary {
                collectDictionary(nested, into: &values, prefix: path)
            } else if let array = value as? NSArray {
                for (index, child) in array.enumerated() {
                    if let nested = child as? NSDictionary {
                        collectDictionary(nested, into: &values, prefix: "\(path)[\(index)]")
                    }
                }
            }
        }
        let channelFields = ["GainMapMin", "GainMapMax", "Gamma", "BaseOffset", "AlternateOffset"]
        for prefix in ["HDRToneMap", "GainMap", "hdrgm"] {
            for index in 0..<3 {
                for field in channelFields {
                    let path = "\(prefix):ChannelMetadata[\(index)].\(field)"
                    if let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
                       let value = CGImageMetadataTagCopyValue(tag) {
                        values[normalizeKey(field)] = value
                        values[normalizeKey(path)] = value
                    }
                }
            }
        }
    }

    private static func firstValue(_ aliases: [String], in values: [String: Any]) -> Any? {
        for alias in aliases {
            if let value = values[normalizeKey(alias)] { return value }
        }
        let normalizedAliases = aliases.map(normalizeKey)
        for (key, value) in values {
            let normalizedKey = normalizeKey(key)
            if normalizedAliases.contains(where: { normalizedKey.hasSuffix($0) }) { return value }
        }
        return nil
    }

    private static func stringValue(named aliases: [String], in values: [String: Any]) -> String? {
        stringValue(firstValue(aliases, in: values))
    }

    private static func namedValue(_ aliases: [String], in dictionary: [CFString: Any]) -> Any? {
        let normalizedAliases = aliases.map(normalizeKey)
        for (key, value) in dictionary {
            let normalizedKey = normalizeKey(String(describing: key))
            if normalizedAliases.contains(where: { normalizedKey == $0 || normalizedKey.hasSuffix($0) }) {
                return value
            }
        }
        return nil
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let direct = Double(cleaned) { return direct }
            let parts = cleaned.split(separator: "/", maxSplits: 1).compactMap { Double($0) }
            if parts.count == 2, abs(parts[1]) > .ulpOfOne { return parts[0] / parts[1] }
        }
        if let array = value as? NSArray, let first = array.firstObject { return numberValue(first) }
        return nil
    }

    private static func numberValue(named aliases: [String], in dictionary: [CFString: Any]) -> Double? {
        numberValue(namedValue(aliases, in: dictionary))
    }

    private static func stringArrayValue(_ value: Any?) -> String {
        if let array = value as? NSArray {
            return array.compactMap { stringValue($0) }.joined(separator: ", ")
        }
        if let array = value as? [Any] {
            return array.compactMap { stringValue($0) }.joined(separator: ", ")
        }
        return stringValue(value) ?? ""
    }

    private static func enumValue(_ value: Any?, values: [Int: String]) -> String {
        if let number = numberValue(value) { return values[Int(number.rounded())] ?? String(Int(number.rounded())) }
        return stringValue(value) ?? ""
    }

    private static func flashValue(_ value: Any?) -> String {
        guard let raw = numberValue(value) else { return stringValue(value) ?? "" }
        let fired = Int(raw.rounded()) & 1
        return fired == 1 ? "已闪光（原始值 \(Int(raw.rounded()))）" : "未闪光（原始值 \(Int(raw.rounded()))）"
    }

    private static func gpsCoordinate(latitude: Bool, in dictionary: [CFString: Any]) -> String {
        let values = numberValues(named: [latitude ? "Latitude" : "Longitude"], in: dictionary)
        guard values.count >= 3 else { return "" }
        let degrees = values[0] + values[1] / 60 + values[2] / 3600
        let ref = stringValue(namedValue([latitude ? "LatitudeRef" : "LongitudeRef"], in: dictionary)) ?? ""
        let sign = ["S", "W"].contains(ref.uppercased()) ? -1.0 : 1.0
        return String(format: "%.6f° %@", degrees * sign, ref.uppercased())
    }

    private static func numberValues(named aliases: [String], in dictionary: [CFString: Any]) -> [Double] {
        guard let value = namedValue(aliases, in: dictionary) else { return [] }
        if let array = value as? NSArray { return array.compactMap(numberValue) }
        if let array = value as? [Any] { return array.compactMap(numberValue) }
        if let number = numberValue(value) { return [number] }
        if let string = value as? String {
            return string.split { $0 == "," || $0 == ";" || $0 == " " }
                .compactMap { Double($0) }
        }
        return []
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func doubleValues(_ value: Any?) -> [Double] {
        guard let value else { return [] }
        if let number = value as? NSNumber { return [number.doubleValue] }
        if let array = value as? NSArray { return array.flatMap { doubleValues($0) } }
        if let string = value as? String {
            let cleaned = string.replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
            return cleaned.split { $0 == "," || $0 == ";" || $0 == " " || $0 == "\t" }
                .compactMap { Double($0) }
        }
        return []
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? NSNumber { return value.boolValue }
        guard let string = stringValue(value)?.lowercased() else { return nil }
        switch string {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: return nil
        }
    }

    private static func numericValue(in value: Any, matching keys: [String]) -> Double? {
        if let dict = value as? [CFString: Any] {
            for (key, child) in dict {
                if keys.contains(where: { String(key).lowercased().contains($0) }) {
                    if let number = child as? NSNumber { return number.doubleValue }
                }
                if let found = numericValue(in: child, matching: keys) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array { if let found = numericValue(in: child, matching: keys) { return found } }
        }
        return nil
    }

    static func histogram(for image: CGImage) -> HistogramData {
        analyze(image: image).histogram
    }

    static func analyze(image: CGImage, domain requestedDomain: HistogramData.Domain? = nil) -> ImageAnalysisResult {
        guard let buffer = renderLinearBuffer(image) else {
            return ImageAnalysisResult(histogram: .empty, analysis: .empty)
        }
        let domain = requestedDomain ?? inferredDomain(for: image)
        return analyze(buffer: buffer, domain: domain)
    }

    private static func analyze(buffer: LinearBuffer, domain requestedDomain: HistogramData.Domain? = nil) -> ImageAnalysisResult {
        var histogram = HistogramData()
        histogram.domain = requestedDomain ?? .sdr
        histogram.maximumHDRStops = 4
        histogram.sourceDescription = buffer.samplingDescription
        var analysis = ImageAnalysisData()
        let width = buffer.width
        let height = buffer.height
        var luminances: [Double] = []
        var saturations: [Double] = []
        luminances.reserveCapacity(width * height)
        saturations.reserveCapacity(width * height)
        var lumaGrid = Array(repeating: -1.0, count: width * height)
        var sumLuma = 0.0
        var sumSaturation = 0.0
        var sumHueX = 0.0
        var sumHueY = 0.0
        var meanR = 0.0
        var meanG = 0.0
        var meanB = 0.0
        var validCount = 0
        var sdrWhiteCount = 0
        var extendedCount = 0
        var maximumLuminance = 0.0
        var hdrPixelCount = 0
        var hdrStop1Count = 0
        var hdrStop2Count = 0
        var hdrStop3Count = 0
        var hdrStop4Count = 0
        var sdrHighlightCount = 0
        var sdrHighlightSaturation = 0.0
        var hdrHighlightCount = 0
        var hdrHighlightSaturation = 0.0
        var redClipCount = 0
        var greenClipCount = 0
        var blueClipCount = 0
        var highlightClipCount = 0
        var skinCount = 0
        var skinHueX = 0.0
        var skinHueY = 0.0
        var skinSaturation = 0.0
        var vectorscope = Array(repeating: 0.0, count: 72 * 24)
        var skinVectorscope = Array(repeating: 0.0, count: 72 * 24)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = max(0, min(1, buffer.float(at: offset + 3)))
                guard alpha > 0.001 else { continue }
                var r = buffer.float(at: offset)
                var g = buffer.float(at: offset + 1)
                var b = buffer.float(at: offset + 2)
                if alpha < 0.999 {
                    r /= alpha; g /= alpha; b /= alpha
                }
                if !buffer.isLinear {
                    r = sRGBToLinear(r)
                    g = sRGBToLinear(g)
                    b = sRGBToLinear(b)
                }
                guard r.isFinite, g.isFinite, b.isFinite else { continue }
                let luma = max(0, 0.2289746 * r + 0.6917385 * g + 0.0792869 * b)
                let encodedR = linearToSRGB(max(0, r))
                let encodedG = linearToSRGB(max(0, g))
                let encodedB = linearToSRGB(max(0, b))
                let hsv = rgbToHSV(r: encodedR, g: encodedG, b: encodedB)
                let hueRadians = hsv.hue * .pi / 180

                histogram.red[histogramBin(r, domain: histogram.domain)] += 1
                histogram.green[histogramBin(g, domain: histogram.domain)] += 1
                histogram.blue[histogramBin(b, domain: histogram.domain)] += 1
                histogram.luminance[histogramBin(luma, domain: histogram.domain)] += 1
                histogram.sampleCount += 1
                validCount += 1
                sumLuma += luma
                sumSaturation += hsv.saturation
                sumHueX += cos(hueRadians) * hsv.saturation
                sumHueY += sin(hueRadians) * hsv.saturation
                meanR += r; meanG += g; meanB += b
                maximumLuminance = max(maximumLuminance, luma)
                luminances.append(luma)
                saturations.append(hsv.saturation)
                lumaGrid[y * width + x] = luma
                if luma >= 1 { sdrWhiteCount += 1 }
                if luma >= 0.9 && luma <= 1 {
                    sdrHighlightCount += 1
                    sdrHighlightSaturation += hsv.saturation
                }
                if luma > 1 { hdrPixelCount += 1 }
                if luma > 1 {
                    hdrHighlightCount += 1
                    hdrHighlightSaturation += hsv.saturation
                }
                if luma >= 2 { hdrStop1Count += 1 }
                if luma >= 4 { hdrStop2Count += 1 }
                if luma >= 8 { hdrStop3Count += 1 }
                if luma >= 16 { hdrStop4Count += 1; extendedCount += 1 }
                if r >= 1 { redClipCount += 1 }
                if g >= 1 { greenClipCount += 1 }
                if b >= 1 { blueClipCount += 1 }
                if max(r, max(g, b)) >= 1 { highlightClipCount += 1 }
                if luma > 0 {
                    let radius = min(1, hsv.saturation)
                    let angleIndex = min(71, max(0, Int((hsv.hue / 360) * 72)))
                    let radiusIndex = min(23, max(0, Int(radius * 24)))
                    vectorscope[angleIndex * 24 + radiusIndex] += 1
                }

                if isSkinCandidate(r: encodedR, g: encodedG, b: encodedB, hue: hsv.hue,
                                   saturation: hsv.saturation, brightness: hsv.brightness) {
                    skinCount += 1
                    skinHueX += cos(hueRadians)
                    skinHueY += sin(hueRadians)
                    skinSaturation += hsv.saturation
                    let radius = min(1, hsv.saturation)
                    let angleIndex = min(71, max(0, Int((hsv.hue / 360) * 72)))
                    let radiusIndex = min(23, max(0, Int(radius * 24)))
                    skinVectorscope[angleIndex * 24 + radiusIndex] += 1
                }
            }
        }

        guard validCount > 0 else {
            histogram.sampleStatus = "解码完成，但没有可统计像素"
            return ImageAnalysisResult(histogram: histogram, analysis: .empty)
        }

        histogram.usesExtendedRange = extendedCount > 0
        histogram.highlightRatio = Double(sdrWhiteCount) / Double(validCount)
        histogram.extendedHighlightRatio = Double(extendedCount) / Double(validCount)
        histogram.shadowRatio = Double(luminances.filter { $0 <= 0.001 }.count) / Double(validCount)
        histogram.validSampleCount = validCount
        histogram.redClipRatio = Double(redClipCount) / Double(validCount)
        histogram.greenClipRatio = Double(greenClipCount) / Double(validCount)
        histogram.blueClipRatio = Double(blueClipCount) / Double(validCount)
        histogram.highlightClipRatio = Double(highlightClipCount) / Double(validCount)
        histogram.sampleStatus = "有效采样 \(validCount) / \(width * height)"

        luminances.sort()
        saturations.sort()
        let p01 = percentile(luminances, 0.01)
        let p05 = percentile(luminances, 0.05)
        let p50 = percentile(luminances, 0.50)
        let p95 = percentile(luminances, 0.95)
        let p99 = percentile(luminances, 0.99)
        analysis.sampleCount = width * height
        analysis.validSampleCount = validCount
        analysis.meanLuminance = sumLuma / Double(validCount)
        analysis.medianLuminance = p50
        analysis.percentile01Luminance = p01
        analysis.percentile05Luminance = p05
        analysis.percentile95Luminance = p95
        analysis.percentile99Luminance = p99
        if let p01, let p99 {
            analysis.effectiveDynamicRangeEV = log2(max(p99, 0.000001) / max(p01, 0.000001))
        }
        if let p05, let p95 {
            analysis.tonalContrastEV = log2(max(p95, 0.000001) / max(p05, 0.000001))
        }
        analysis.sdrWhiteRatio = histogram.highlightRatio
        analysis.extendedHighlightRatio = histogram.extendedHighlightRatio
        analysis.shadowClipRatio = histogram.shadowRatio
        analysis.meanSaturation = sumSaturation / Double(validCount)
        analysis.percentile95Saturation = percentile(saturations, 0.95)
        analysis.meanHueDegrees = hueDegrees(x: sumHueX, y: sumHueY)
        analysis.neutralBalance = sqrt(pow(meanR / Double(validCount) - meanG / Double(validCount), 2) +
                                       pow(meanG / Double(validCount) - meanB / Double(validCount), 2) +
                                       pow(meanB / Double(validCount) - meanR / Double(validCount), 2))
        analysis.outOfGamutRatio = Double(luminances.filter { $0 > 1 }.count) / Double(validCount)
        analysis.detailEnergy = detailEnergy(lumaGrid: lumaGrid, width: width, height: height)
        analysis.maximumLuminance = maximumLuminance
        analysis.p99HeadroomEV = p99.map { max(0, log2(max(1, $0))) }
        analysis.hdrPixelRatio = Double(hdrPixelCount) / Double(validCount)
        analysis.hdrStop1Ratio = Double(hdrStop1Count) / Double(validCount)
        analysis.hdrStop2Ratio = Double(hdrStop2Count) / Double(validCount)
        analysis.hdrStop3Ratio = Double(hdrStop3Count) / Double(validCount)
        analysis.hdrStop4Ratio = Double(hdrStop4Count) / Double(validCount)
        analysis.sdrHighlightMeanSaturation = sdrHighlightCount > 0
            ? sdrHighlightSaturation / Double(sdrHighlightCount) : nil
        analysis.hdrHighlightMeanSaturation = hdrHighlightCount > 0
            ? hdrHighlightSaturation / Double(hdrHighlightCount) : nil

        let skinMeanHue = skinCount > 0 ? hueDegrees(x: skinHueX, y: skinHueY) : nil
        var skin = SkinToneStats()
        skin.candidateCount = skinCount
        skin.candidateRatio = Double(skinCount) / Double(validCount)
        skin.meanHueDegrees = skinMeanHue
        skin.meanSaturation = skinCount > 0 ? skinSaturation / Double(skinCount) : nil
        skin.lineDeviationDegrees = skinMeanHue.map { circularDistance($0, from: skin.lineAngleDegrees) }
        if skinCount > 0 {
            var variance = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let alpha = buffer.float(at: offset + 3)
                    guard alpha > 0.001 else { continue }
                    var r = buffer.float(at: offset), g = buffer.float(at: offset + 1), b = buffer.float(at: offset + 2)
                    if alpha < 0.999 { r /= alpha; g /= alpha; b /= alpha }
                    if !buffer.isLinear { r = sRGBToLinear(r); g = sRGBToLinear(g); b = sRGBToLinear(b) }
                    let hsv = rgbToHSV(r: linearToSRGB(max(0, r)), g: linearToSRGB(max(0, g)), b: linearToSRGB(max(0, b)))
                    if isSkinCandidate(r: linearToSRGB(max(0, r)), g: linearToSRGB(max(0, g)), b: linearToSRGB(max(0, b)),
                                       hue: hsv.hue, saturation: hsv.saturation, brightness: hsv.brightness),
                       let mean = skinMeanHue {
                        variance += pow(circularDistance(hsv.hue, from: mean), 2)
                    }
                }
            }
            skin.hueStdDevDegrees = sqrt(variance / Double(skinCount))
        }
        skin.vectorscopeBins = vectorscope.map { $0 / Double(validCount) }
        skin.skinVectorscopeBins = skinVectorscope.map { $0 / Double(validCount) }
        analysis.skin = skin
        return ImageAnalysisResult(histogram: histogram, analysis: analysis)
    }

    /// Detect faces with Vision and re-run the skin candidate statistics only
    /// inside the detected face rectangles. The full-frame report remains
    /// unchanged; this returns a copy with an additional face-scoped result.
    static func analyzeFaces(image: CGImage, base: ImageAnalysisData) -> ImageAnalysisData {
        var result = base
        var skin = base.skin
        guard let buffer = renderLinearBuffer(image) else {
            skin.faceAnalysisState = "分析失败：无法建立采样缓冲"
            result.skin = skin
            return result
        }

        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            skin.faceAnalysisState = "分析失败：人脸检测不可用"
            result.skin = skin
            return result
        }

        let boxes = (request.results ?? []).map(\.boundingBox).filter {
            $0.width > 0.01 && $0.height > 0.01
        }
        skin.faceCount = boxes.count
        skin.faceSampleCount = 0
        skin.faceCandidateCount = 0
        skin.faceCandidateRatio = 0
        skin.faceMeanHueDegrees = nil
        skin.faceHueStdDevDegrees = nil
        skin.faceMeanSaturation = nil
        skin.faceLineDeviationDegrees = nil

        guard !boxes.isEmpty else {
            skin.faceAnalysisState = "已分析：未检测到人脸"
            result.skin = skin
            return result
        }

        var sampleCount = 0
        var candidateCount = 0
        var hueX = 0.0
        var hueY = 0.0
        var saturationSum = 0.0
        var candidateHues: [Double] = []
        candidateHues.reserveCapacity(max(16, buffer.width * buffer.height / 20))

        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                // Vision and Core Graphics both use a bottom-left normalized
                // image coordinate for this request path.
                let point = CGPoint(x: (Double(x) + 0.5) / Double(buffer.width),
                                    y: (Double(y) + 0.5) / Double(buffer.height))
                guard boxes.contains(where: { $0.contains(point) }) else { continue }

                let offset = (y * buffer.width + x) * 4
                let alpha = max(0, min(1, buffer.float(at: offset + 3)))
                guard alpha > 0.001 else { continue }
                var r = buffer.float(at: offset)
                var g = buffer.float(at: offset + 1)
                var b = buffer.float(at: offset + 2)
                if alpha < 0.999 { r /= alpha; g /= alpha; b /= alpha }
                if !buffer.isLinear {
                    r = sRGBToLinear(r)
                    g = sRGBToLinear(g)
                    b = sRGBToLinear(b)
                }
                guard r.isFinite, g.isFinite, b.isFinite else { continue }
                let encodedR = linearToSRGB(max(0, r))
                let encodedG = linearToSRGB(max(0, g))
                let encodedB = linearToSRGB(max(0, b))
                let hsv = rgbToHSV(r: encodedR, g: encodedG, b: encodedB)
                sampleCount += 1
                if isSkinCandidate(r: encodedR, g: encodedG, b: encodedB,
                                   hue: hsv.hue, saturation: hsv.saturation,
                                   brightness: hsv.brightness) {
                    candidateCount += 1
                    hueX += cos(hsv.hue * .pi / 180)
                    hueY += sin(hsv.hue * .pi / 180)
                    saturationSum += hsv.saturation
                    candidateHues.append(hsv.hue)
                }
            }
        }

        skin.faceAnalysisState = "已分析"
        skin.faceSampleCount = sampleCount
        skin.faceCandidateCount = candidateCount
        skin.faceCandidateRatio = sampleCount > 0 ? Double(candidateCount) / Double(sampleCount) : 0
        let meanHue = hueDegrees(x: hueX, y: hueY)
        skin.faceMeanHueDegrees = meanHue
        skin.faceMeanSaturation = candidateCount > 0 ? saturationSum / Double(candidateCount) : nil
        skin.faceLineDeviationDegrees = meanHue.map { circularDistance($0, from: skin.lineAngleDegrees) }
        if let meanHue, !candidateHues.isEmpty {
            let variance = candidateHues.reduce(0.0) {
                $0 + pow(circularDistance($1, from: meanHue), 2)
            } / Double(candidateHues.count)
            skin.faceHueStdDevDegrees = sqrt(variance)
        }
        result.skin = skin
        return result
    }

    private struct LinearBuffer {
        let data: Data
        let width: Int
        let height: Int
        let isLinear: Bool
        let samplingDescription: String

        func float(at index: Int) -> Double {
            data.withUnsafeBytes { raw in
                Double(raw.load(fromByteOffset: index * MemoryLayout<Float>.size, as: Float.self))
            }
        }
    }

    private struct EncodedBuffer {
        let data: Data
        let width: Int
        let height: Int

        func value(at index: Int) -> Double {
            Double(data[index]) / 255.0
        }
    }

    private static func renderLinearBuffer(_ image: CGImage, maximumDimension requestedMaximumDimension: Int = 384) -> LinearBuffer? {
        let maximumDimension = max(1, requestedMaximumDimension)
        let scale = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue |
            CGBitmapInfo.floatComponents.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        if width == image.width, height == image.height, let direct = directFloatBuffer(image) {
            return direct
        }
        func render(using colorSpace: CGColorSpace, isLinear: Bool) -> LinearBuffer? {
            var data = Data(count: width * height * 4 * MemoryLayout<Float>.size)
            let rendered = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                               bitsPerComponent: 32, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                                               space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                context.flush()
                return true
            }
            return rendered ? LinearBuffer(data: data, width: width, height: height, isLinear: isLinear,
                                          samplingDescription: isLinear ? "ColorSync 32-bit float 线性采样" : "ColorSync 32-bit float 非线性采样") : nil
        }
        if let extendedSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
           let result = render(using: extendedSpace, isLinear: true) {
            return result
        }
        if let extendedSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
           let result = render(using: extendedSRGB, isLinear: true) {
            return result
        }
        // Some older renderers and headless test contexts cannot create an
        // extended-linear bitmap. Device RGB remains a valid SDR fallback;
        // it is explicitly marked non-linear so the statistics do not claim
        // that the fallback preserved HDR headroom.
        if let result = render(using: CGColorSpaceCreateDeviceRGB(), isLinear: false) {
            return result
        }
        return render8Bit(image, width: width, height: height)
    }

    private static func renderNormalizedBuffer(_ image: CGImage, width: Int, height: Int) -> EncodedBuffer? {
        guard width > 0, height > 0 else { return nil }
        var data = Data(repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                           bitsPerComponent: 8, bytesPerRow: width * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.flush()
            return true
        }
        return rendered ? EncodedBuffer(data: data, width: width, height: height) : nil
    }

    private static func makeImage(from buffer: LinearBuffer) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue |
            CGBitmapInfo.floatComponents.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(data: buffer.data as CFData) else { return nil }
        return CGImage(width: buffer.width, height: buffer.height,
                       bitsPerComponent: 32, bitsPerPixel: 128,
                       bytesPerRow: buffer.width * 4 * MemoryLayout<Float>.size,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func render8Bit(_ image: CGImage, width: Int, height: Int) -> LinearBuffer? {
        var data = Data(count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                           bitsPerComponent: 8, bytesPerRow: width * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.flush()
            return true
        }
        guard rendered else { return nil }
        var floats = [Float](repeating: 0, count: width * height * 4)
        data.withUnsafeBytes { raw in
            for index in 0..<width * height {
                let source = index * 4
                let target = source
                floats[target] = Float(raw[source]) / 255
                floats[target + 1] = Float(raw[source + 1]) / 255
                floats[target + 2] = Float(raw[source + 2]) / 255
                floats[target + 3] = Float(raw[source + 3]) / 255
            }
        }
        return LinearBuffer(data: Data(bytes: floats, count: floats.count * MemoryLayout<Float>.size),
                            width: width, height: height, isLinear: false,
                            samplingDescription: "8-bit RGB 兼容采样（HDR 扩展范围不可保留）")
    }

    private static func directFloatBuffer(_ image: CGImage) -> LinearBuffer? {
        guard image.bitsPerComponent == 32, image.bitsPerPixel == 128,
              let source = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(source) else { return nil }
        let alpha = image.alphaInfo
        let hasAlpha = alpha == .premultipliedFirst || alpha == .premultipliedLast ||
            alpha == .first || alpha == .last
        let littleEndian = image.bitmapInfo.contains(.byteOrder32Little)
        let isAlphaLast = alpha == .premultipliedLast || alpha == .last || alpha == .noneSkipLast
        let isAlphaFirst = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
        guard isAlphaLast || isAlphaFirst else { return nil }
        let channelIndices: (Int, Int, Int, Int) = {
            if littleEndian && isAlphaLast { return (2, 1, 0, 3) }
            if littleEndian && isAlphaFirst { return (3, 2, 1, 0) }
            if isAlphaLast { return (0, 1, 2, 3) }
            return (1, 2, 3, 0)
        }()
        var output = [Float](repeating: 0, count: image.width * image.height * 4)
        for y in 0..<image.height {
            let row = pointer.advanced(by: y * image.bytesPerRow)
            for x in 0..<image.width {
                let sourceOffset = x * 16
                let targetOffset = (y * image.width + x) * 4
                func read(_ channel: Int) -> Float {
                    row.advanced(by: sourceOffset + channel * 4)
                        .withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
                }
                output[targetOffset] = read(channelIndices.0)
                output[targetOffset + 1] = read(channelIndices.1)
                output[targetOffset + 2] = read(channelIndices.2)
                output[targetOffset + 3] = hasAlpha ? read(channelIndices.3) : 1
            }
        }
        let colorName = image.colorSpace?.name as String? ?? ""
        // Float storage does not imply linear transfer. PQ/HLG float images
        // must go through ColorSync so their transfer function is decoded
        // before statistics are calculated.
        guard !colorName.localizedCaseInsensitiveContains("pq"),
              !colorName.localizedCaseInsensitiveContains("hlg") else { return nil }
        let isLinear = colorName.localizedCaseInsensitiveContains("linear")
        return LinearBuffer(data: Data(bytes: output, count: output.count * MemoryLayout<Float>.size),
                            width: image.width, height: image.height, isLinear: isLinear,
                            samplingDescription: "原始 32-bit float 像素采样")
    }

    private static func inferredDomain(for image: CGImage) -> HistogramData.Domain {
        let name = image.colorSpace?.name as String? ?? ""
        return name.localizedCaseInsensitiveContains("pq") ||
            name.localizedCaseInsensitiveContains("hlg") ||
            name.localizedCaseInsensitiveContains("extended") ? .hdr : .sdr
    }

    private static func histogramBin(_ value: Double, domain: HistogramData.Domain) -> Int {
        guard value.isFinite else { return 0 }
        if domain == .sdr {
            // Adobe's normal histogram is a display-referred 0–255 scale.
            // The analysis buffer is linear-light, so encode the SDR portion
            // before assigning a bin. This also makes the SDR half of an HDR
            // histogram use exactly the same samples and transfer curve.
            return min(255, max(0, Int((linearToSRGB(value) * 255).rounded())))
        }
        return dynamicRangeBin(value)
    }

    private static func dynamicRangeBin(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        if value <= 1 {
            // HDR histograms reserve the left half for SDR. Within that half,
            // Adobe reports ordinary SDR values as 0–255 display values.
            return min(127, max(0, Int((linearToSRGB(value) * 127).rounded())))
        }
        let stops = min(4, max(0, log2(value)))
        return min(255, max(128, 128 + Int((stops / 4 * 127).rounded())))
    }

    private static func sRGBToLinear(_ value: Double) -> Double {
        let v = min(1, max(0, value))
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Double) -> Double {
        let v = min(1, max(0, value))
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static func rgbToHSV(r: Double, g: Double, b: Double) -> (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(r, max(g, b))
        let minimum = min(r, min(g, b))
        let delta = maximum - minimum
        guard delta > 0.000001 else { return (0, 0, maximum) }
        var hue: Double
        if maximum == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maximum == g { hue = 60 * ((b - r) / delta + 2) }
        else { hue = 60 * ((r - g) / delta + 4) }
        if hue < 0 { hue += 360 }
        return (hue, delta / max(maximum, 0.000001), maximum)
    }

    private static func isSkinCandidate(r: Double, g: Double, b: Double, hue: Double,
                                        saturation: Double, brightness: Double) -> Bool {
        guard brightness > 0.05, saturation >= 0.10, saturation <= 0.85,
              (hue <= 55 || hue >= 350) else { return false }
        let cb = 128 - 0.168736 * r * 255 - 0.331264 * g * 255 + 0.5 * b * 255
        let cr = 128 + 0.5 * r * 255 - 0.418688 * g * 255 - 0.081312 * b * 255
        return (cb >= 70 && cb <= 145 && cr >= 125 && cr <= 185)
    }

    private static func percentile(_ values: [Double], _ position: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let index = min(values.count - 1, max(0, Int((Double(values.count - 1) * position).rounded())))
        return values[index]
    }

    private static func hueDegrees(x: Double, y: Double) -> Double? {
        guard abs(x) > 0.000001 || abs(y) > 0.000001 else { return nil }
        var degrees = atan2(y, x) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    private static func circularDistance(_ value: Double, from reference: Double) -> Double {
        let delta = abs(value - reference).truncatingRemainder(dividingBy: 360)
        return min(delta, 360 - delta)
    }

    private static func detailEnergy(lumaGrid: [Double], width: Int, height: Int) -> Double? {
        guard width > 1, height > 1 else { return nil }
        var total = 0.0
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let current = lumaGrid[y * width + x]
                guard current >= 0 else { continue }
                if x + 1 < width {
                    let right = lumaGrid[y * width + x + 1]
                    if right >= 0 { total += abs(current - right) / max(0.01, current + right); count += 1 }
                }
                if y + 1 < height {
                    let down = lumaGrid[(y + 1) * width + x]
                    if down >= 0 { total += abs(current - down) / max(0.01, current + down); count += 1 }
                }
            }
        }
        return count > 0 ? total / Double(count) : nil
    }

    static func makeThumbnail(url: URL, size: Int = 420, sdr: Bool = false) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceDecodeRequest: sdr ? kCGImageSourceDecodeToSDR : kCGImageSourceDecodeToHDR
              ] as CFDictionary) else {
            if let raw = CIRAWFilter(imageURL: url) {
                raw.isDraftModeEnabled = true
                raw.scaleFactor = 0.15
                raw.extendedDynamicRangeAmount = sdr ? 0 : 1
                if let output = raw.outputImage,
                   let image = context.createCGImage(output, from: output.extent) { return image }
            }
            throw NSError(domain: "OneImageCompare", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法生成缩略图"])
        }
        return image
    }
}
