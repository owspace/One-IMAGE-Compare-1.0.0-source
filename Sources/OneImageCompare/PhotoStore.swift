import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

@MainActor
final class PhotoStore: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var selection: Set<UUID> = []
    @Published var mode: AppMode = .browser
    @Published var hdrMode: HDRMode = .hdr { didSet { reloadSelectedPreviews() } }
    @Published var theme: AppTheme = .neutral
    @Published var sortOrder: SortOrder = .added
    @Published var query = ""
    @Published var formatFilter = "全部"
    @Published var hdrFilter = "全部"
    @Published var inspectorVisible = true
    @Published var sidebarVisible = true
    @Published var histogramChannel = "RGB"
    @Published var inspectorTab: InspectorTab = .gainMap
    @Published var histogramExpanded = true
    @Published var effectAnalysisVisible = false
    @Published var effectAnalysisScope: EffectAnalysisScope = .hdr
    @Published var zoom: CGFloat = 1
    @Published var syncPan = true {
        didSet {
            if syncPan { synchronizeCompareViewports() }
        }
    }
    @Published var viewportStates: [UUID: ViewportState] = [:]
    @Published var sharedViewport = ViewportState.fit
    @Published var status = "打开文件或文件夹开始"
    @Published var loadingProgress = 0.0
    @Published var isWorking = false
    @Published var selectedInspectorID: UUID?
    @Published var referenceID: UUID?
    private var selectionAnchorID: UUID?

    var visiblePhotos: [PhotoItem] {
        let filtered = photos.filter { photo in
            (query.isEmpty || photo.url.lastPathComponent.localizedCaseInsensitiveContains(query)) &&
            (formatFilter == "全部" || photo.url.pathExtension.uppercased() == formatFilter) &&
            (hdrFilter == "全部" || (hdrFilter == "HDR" ? photo.metadata.hdr.isHDR : !photo.metadata.hdr.isHDR))
        }
        return filtered.sorted {
            switch sortOrder {
            case .name: return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            case .captureDate: return $0.metadata.captureDate < $1.metadata.captureDate
            case .size: return $0.metadata.fileSize < $1.metadata.fileSize
            case .added: return $0.addedIndex < $1.addedIndex
            }
        }
    }
    var selectedPhotos: [PhotoItem] {
        photos.filter { selection.contains($0.id) }.sorted { $0.addedIndex < $1.addedIndex }
    }
    var inspectorPhoto: PhotoItem? {
        if let id = selectedInspectorID, let item = photos.first(where: { $0.id == id }) { return item }
        return selectedPhotos.first
    }
    var availableFormats: [String] {
        ["全部"] + Array(Set(photos.map { $0.url.pathExtension.uppercased() })).sorted()
    }

    var activeViewportID: UUID? { selectedInspectorID ?? selectedPhotos.first?.id }

    func viewport(for id: UUID) -> ViewportState {
        viewportStates[id] ?? (mode == .compare && syncPan ? sharedViewport : .fit)
    }

    func updateViewport(_ state: ViewportState, for id: UUID) {
        if mode == .compare, syncPan {
            sharedViewport = state
            var updated = viewportStates
            for item in selectedPhotos { updated[item.id] = state }
            viewportStates = updated
        } else {
            var updated = viewportStates
            updated[id] = state
            viewportStates = updated
        }
        zoom = state.zoom
    }

    func setToolbarZoom(_ value: CGFloat) {
        let newZoom = ViewportMath.clampedZoom(value)
        guard let id = activeViewportID else { zoom = newZoom; return }
        var state = viewport(for: id)
        state.zoom = newZoom
        state.preset = newZoom == 1 ? .fit : .manual
        updateViewport(state, for: id)
    }

    private func synchronizeCompareViewports() {
        guard mode == .compare, let first = selectedPhotos.first else { return }
        let state = viewportStates[first.id] ?? sharedViewport
        sharedViewport = state
        var updated = viewportStates
        for item in selectedPhotos { updated[item.id] = state }
        viewportStates = updated
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .rawImage]
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
            let urls = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                .compactMap { $0 as? URL }
                .filter { ImagePipeline.isSupported($0) }) ?? []
            await MainActor.run { self.importURLs(urls) }
        }
    }

    func importURLs(_ urls: [URL]) {
        let existing = Set(photos.map(\.url.path))
        let accepted = urls.filter { ImagePipeline.isSupported($0) && !existing.contains($0.path) }
        let start = photos.count
        photos.append(contentsOf: accepted.enumerated().map { PhotoItem(url: $0.element, addedIndex: start + $0.offset) })
        status = accepted.isEmpty ? "没有发现新的受支持图片" : "已导入 \(accepted.count) 张，正在生成缩略图"
        loadThumbnails(for: Array(photos.suffix(accepted.count)))
    }

    func loadThumbnails(for items: [PhotoItem]) {
        guard !items.isEmpty else { return }
        isWorking = true
        loadingProgress = 0
        let useSDR = hdrMode == .sdr
        let loadedMode: HDRMode = useSDR ? .sdr : .hdr
        Task {
            await withTaskGroup(of: (UUID, CGImage?, PhotoMetadata?, HistogramData?, ImageAnalysisData?, String?).self) { group in
                for item in items {
                    let url = item.url
                    group.addTask {
                        do {
                            let cg = try ImagePipeline.makeThumbnail(url: url, sdr: useSDR)
                            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
                            let metadata = source.map { ImagePipeline.readMetadata(source: $0, url: url) }
                            var measured = ImagePipeline.analyze(image: cg,
                                                                 domain: useSDR ? .sdr : .hdr)
                            measured.histogram.contentHeadroomEV = metadata?.hdr.headroom.map { max(0, log2(max(1, $0))) }
                                ?? metadata?.gainMap.alternateHDRHeadroom.map { max(0, $0) }
                            return (item.id, cg, metadata, measured.histogram, measured.analysis, nil)
                        } catch { return (item.id, nil, nil, nil, nil, error.localizedDescription) }
                    }
                }
                var completed = 0
                for await (id, cg, metadata, histogram, analysis, error) in group {
                    if let item = photos.first(where: { $0.id == id }) {
                        if let cg {
                            item.thumbnailCGImage = cg
                            item.thumbnail = NSImage(cgImage: cg, size: .zero)
                        }
                        if let metadata { item.metadata = metadata }
                        if let histogram {
                            if useSDR { item.sdrHistogram = histogram } else { item.hdrHistogram = histogram }
                            if self.hdrMode == loadedMode { item.histogram = histogram }
                        }
                        if let analysis {
                            if useSDR { item.sdrAnalysis = analysis } else { item.hdrAnalysis = analysis }
                            if self.hdrMode == loadedMode { item.analysis = analysis }
                        }
                        item.error = error
                    }
                    completed += 1
                    loadingProgress = Double(completed) / Double(items.count)
                }
            }
            isWorking = false
            status = "共 \(photos.count) 张照片"
        }
    }

    func toggleSelection(_ item: PhotoItem, extend: Bool) {
        selectThumbnail(item, modifiers: extend ? .command : [])
    }

    func selectThumbnail(_ item: PhotoItem, modifiers: NSEvent.ModifierFlags) {
        let extend = modifiers.contains(.command)
        let rangeSelect = modifiers.contains(.shift)
        if rangeSelect, let anchorID = selectionAnchorID,
           let anchorIndex = visiblePhotos.firstIndex(where: { $0.id == anchorID }),
           let targetIndex = visiblePhotos.firstIndex(where: { $0.id == item.id }) {
            let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
            let rangeIDs = range.map { visiblePhotos[$0].id }
            if rangeIDs.count > 8 { status = "已选择连续范围 (rangeIDs.count) 张；进入对比前请减少到 8 张" }
            selection = extend ? selection.union(rangeIDs) : Set(rangeIDs)
        } else if extend {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        } else {
            selection = [item.id]
        }
        if !rangeSelect {
            selectionAnchorID = item.id
        }
        selectedInspectorID = item.id
        if selection.count == 1, mode != .browser { loadPreview(item) }
    }

    func resetView() {
        if mode == .compare {
            sharedViewport = .fit
            var updated = viewportStates
            for item in selectedPhotos { updated[item.id] = .fit }
            viewportStates = updated
        } else if let id = activeViewportID {
            var updated = viewportStates
            updated[id] = .fit
            viewportStates = updated
        }
        zoom = 1
    }

    func changeZoom(by factor: CGFloat) {
        setToolbarZoom(zoom * factor)
    }

    func selectVisible(upTo limit: Int) {
        selection = Set(visiblePhotos.prefix(limit).map(\.id))
        selectedInspectorID = selectedPhotos.first?.id
        selectionAnchorID = selectedPhotos.first?.id
    }

    func selectAdjacent(_ delta: Int) {
        guard !visiblePhotos.isEmpty else { return }
        let current = inspectorPhoto.flatMap { p in visiblePhotos.firstIndex(where: { $0.id == p.id }) } ?? 0
        let next = min(max(current + delta, 0), visiblePhotos.count - 1)
        if mode == .compare {
            selectedInspectorID = visiblePhotos[next].id
            loadPreview(visiblePhotos[next])
            return
        }
        selection = [visiblePhotos[next].id]
        selectedInspectorID = visiblePhotos[next].id
        selectionAnchorID = visiblePhotos[next].id
        if mode != .browser {
            var updated = viewportStates
            updated[visiblePhotos[next].id] = .fit
            viewportStates = updated
            loadPreview(visiblePhotos[next])
        }
    }

    func enterCompare() {
        guard (2...8).contains(selection.count) else {
            status = selection.count > 8 ? "已选择 (selection.count) 张，请减少到 8 张以内" : "请先选择 2–8 张照片"
            return
        }
        mode = .compare
        sharedViewport = .fit
        var updated = viewportStates
        for item in selectedPhotos { updated[item.id] = .fit }
        viewportStates = updated
        referenceID = referenceID.flatMap { selection.contains($0) ? $0 : nil } ?? selectedPhotos.first?.id
        selectedPhotos.forEach(loadPreview)
    }

    func showViewer(_ item: PhotoItem) {
        selection = [item.id]
        selectedInspectorID = item.id
        selectionAnchorID = item.id
        var updated = viewportStates
        updated[item.id] = .fit
        viewportStates = updated
        if let cached = item.cachedPreview(for: hdrMode) {
            item.preview = cached
            item.displayPreview = cached
            applyCachedMeasurements(to: item, mode: hdrMode)
        } else if item.displayPreview == nil {
            item.displayPreview = item.thumbnailCGImage
        }
        mode = .viewer
    }

    func toggleHDRMode() {
        hdrMode = hdrMode == .hdr ? .sdr : .hdr
    }

    func toggleEffectAnalysis() {
        effectAnalysisVisible.toggle()
        if effectAnalysisVisible {
            inspectorVisible = true
            effectAnalysisScope = hdrMode == .hdr ? .hdr : .sdr
        }
    }

    func loadPreview(_ item: PhotoItem) {
        let requestedMode = hdrMode
        if let cached = item.cachedPreview(for: requestedMode) {
            item.preview = cached
            item.displayPreview = cached
            applyCachedMeasurements(to: item, mode: requestedMode)
            item.loading = false
            item.previewLoadingMode = nil
            if let cachedAnalysis = item.cachedAnalysis(for: requestedMode) {
                autoAnalyzeFacesIfNeeded(item,
                                         image: item.cachedAnalysisImage(for: requestedMode) ?? cached,
                                         base: cachedAnalysis, mode: requestedMode)
            }
            return
        }
        if item.loading && item.previewLoadingMode == requestedMode { return }

        item.previewGeneration += 1
        let generation = item.previewGeneration
        item.loading = true
        item.previewLoadingMode = requestedMode
        if item.displayPreview == nil, let placeholder = item.thumbnailCGImage {
            item.displayPreview = placeholder
        }
        let url = item.url
        let useSDR = requestedMode == .sdr
        Task.detached(priority: .userInitiated) {
            do {
                    let result = try ImagePipeline.load(url: url, maxPixel: 2800, sdr: useSDR)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard item.previewGeneration == generation,
                          item.previewLoadingMode == requestedMode,
                          self.hdrMode == requestedMode else {
                        return
                    }
                    if requestedMode == .sdr {
                        item.sdrPreview = result.displayImage
                        item.sdrAnalysisImage = result.analysisImage
                        item.sdrHistogram = result.histogram
                        item.sdrAnalysis = result.analysis
                    } else {
                        item.hdrPreview = result.displayImage
                        item.hdrAnalysisImage = result.analysisImage
                        item.hdrHistogram = result.histogram
                        item.hdrAnalysis = result.analysis
                    }
                    item.preview = result.displayImage
                    item.displayPreview = result.displayImage
                    item.metadata = result.metadata
                    item.histogram = result.histogram
                    item.analysis = result.analysis
                    item.loading = false
                    item.previewLoadingMode = nil
                    // PhotoItem is an ObservableObject, but the parent view
                    // iterates plain PhotoItem values. Publish once here so
                    // ImageCanvas and the loading overlay refresh immediately
                    // when the detached decode finishes.
                    self.objectWillChange.send()
                    self.autoAnalyzeFacesIfNeeded(item, image: result.analysisImage,
                                                  base: result.analysis, mode: requestedMode)
                }
            } catch {
                await MainActor.run {
                    guard item.previewGeneration == generation,
                          item.previewLoadingMode == requestedMode else { return }
                    item.error = error.localizedDescription
                    item.loading = false
                    item.previewLoadingMode = nil
                    self.objectWillChange.send()
                }
            }
        }
    }

    func ensureEffectAnalysis(_ item: PhotoItem, scope: EffectAnalysisScope) {
        let requestedMode = scope.mode
        if let cached = item.cachedAnalysis(for: requestedMode) {
            if let image = item.cachedAnalysisImage(for: requestedMode) ?? item.cachedPreview(for: requestedMode) {
                autoAnalyzeFacesIfNeeded(item, image: image, base: cached, mode: requestedMode)
                return
            }
            // Thumbnail analysis is enough to populate the browser quickly,
            // but face detection must use the full preview. For the active
            // mode let loadPreview perform that decode; for the inactive mode
            // continue below and replace the thumbnail measurements with a
            // full-resolution analysis cache.
            if requestedMode == hdrMode {
                loadPreview(item)
                return
            }
        }
        if requestedMode == hdrMode {
            loadPreview(item)
            return
        }
        guard !item.analysisLoadingModes.contains(requestedMode) else { return }

        item.analysisLoadingModes.insert(requestedMode)
        item.objectWillChange.send()
        let url = item.url
        Task.detached(priority: .userInitiated) {
            do {
                let result = try ImagePipeline.load(url: url, maxPixel: 2800,
                                                     sdr: requestedMode == .sdr)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if requestedMode == .sdr {
                        item.sdrPreview = result.displayImage
                        item.sdrAnalysisImage = result.analysisImage
                        item.sdrHistogram = result.histogram
                        item.sdrAnalysis = result.analysis
                    } else {
                        item.hdrPreview = result.displayImage
                        item.hdrAnalysisImage = result.analysisImage
                        item.hdrHistogram = result.histogram
                        item.hdrAnalysis = result.analysis
                    }
                    item.metadata = result.metadata
                    item.analysisLoadingModes.remove(requestedMode)
                    if self.hdrMode == requestedMode {
                        item.preview = result.displayImage
                        item.displayPreview = result.displayImage
                        item.histogram = result.histogram
                        item.analysis = result.analysis
                    }
                    item.objectWillChange.send()
                    self.autoAnalyzeFacesIfNeeded(item, image: result.analysisImage,
                                                  base: result.analysis, mode: requestedMode)
                }
            } catch {
                await MainActor.run {
                    item.analysisLoadingModes.remove(requestedMode)
                    self.status = "效果分析解码失败：\(error.localizedDescription)"
                    item.objectWillChange.send()
                }
            }
        }
    }

    private func autoAnalyzeFacesIfNeeded(_ item: PhotoItem, image: CGImage,
                                          base: ImageAnalysisData, mode: HDRMode) {
        guard base.skin.faceAnalysisState == "未分析",
              !item.faceAnalysisLoading else { return }
        item.faceAnalysisLoading = true
        item.objectWillChange.send()
        Task.detached(priority: .userInitiated) {
            let analyzed = ImagePipeline.analyzeFaces(image: image, base: base)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if mode == .sdr {
                    item.sdrAnalysis = analyzed
                } else {
                    item.hdrAnalysis = analyzed
                }
                if self.hdrMode == mode {
                    item.analysis = analyzed
                }
                item.faceAnalysisLoading = false
                item.objectWillChange.send()
            }
        }
    }

    func reloadSelectedPreviews() {
        var needsThumbnailAnalysis: [PhotoItem] = []
        var affected = selectedPhotos
        if let inspectorPhoto,
           !affected.contains(where: { $0.id == inspectorPhoto.id }) {
            affected.append(inspectorPhoto)
        }
        for photo in affected {
            // Invalidate a result that may still be decoding for the previous
            // mode. If this rendition was already decoded, switch immediately.
            photo.previewGeneration += 1
            photo.previewLoadingMode = nil
            photo.loading = false
            if let cached = photo.cachedPreview(for: hdrMode) {
                photo.preview = cached
                photo.displayPreview = cached
                applyCachedMeasurements(to: photo, mode: hdrMode)
            } else {
                photo.displayPreview = mode == .browser ? photo.thumbnailCGImage : nil
                if let cachedHistogram = photo.cachedHistogram(for: hdrMode),
                   let cachedAnalysis = photo.cachedAnalysis(for: hdrMode) {
                    photo.histogram = cachedHistogram
                    photo.analysis = cachedAnalysis
                } else if mode == .browser {
                    needsThumbnailAnalysis.append(photo)
                }
            }
            if mode != .browser { loadPreview(photo) }
        }
        if !needsThumbnailAnalysis.isEmpty { loadThumbnails(for: needsThumbnailAnalysis) }
    }

    private func applyCachedMeasurements(to item: PhotoItem, mode: HDRMode) {
        if let histogram = item.cachedHistogram(for: mode) { item.histogram = histogram }
        if let analysis = item.cachedAnalysis(for: mode) { item.analysis = analysis }
    }

    func autoAlign() {
        guard let reference = selectedPhotos.first(where: { $0.id == referenceID }) ?? selectedPhotos.first,
              let referenceImage = reference.displayPreview else { status = "基准图尚未加载"; return }
        isWorking = true
        status = "正在自动对齐…"
        let targets = selectedPhotos.filter { $0.id != reference.id }
        Task.detached(priority: .userInitiated) {
            for item in targets {
                guard let target = await item.displayPreview else { continue }
                let request = VNTranslationalImageRegistrationRequest(targetedCGImage: referenceImage)
                let handler = VNImageRequestHandler(cgImage: target)
                do {
                    try handler.perform([request])
                    if let observation = request.results?.first as? VNImageTranslationAlignmentObservation {
                        let transform = observation.alignmentTransform
                        await MainActor.run {
                            item.alignment = transform
                            item.alignmentConfidence = 0.8
                        }
                    }
                } catch {
                    await MainActor.run { item.alignmentConfidence = 0 }
                }
            }
            await MainActor.run {
                self.isWorking = false
                self.status = "自动对齐完成；对齐仅改变视图，不修改原文件"
            }
        }
    }

    func resetAlignment() {
        selectedPhotos.forEach { $0.alignment = .identity; $0.alignmentConfidence = nil }
    }

    func saveProject() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "图片对比.oicproject"
        panel.allowedContentTypes = [UTType(filenameExtension: "oicproject") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let doc = ProjectDocument(
            paths: photos.map(\.url.path),
            selection: selectedPhotos.map(\.url.path),
            mode: mode, hdrMode: hdrMode, theme: theme,
            ratings: Dictionary(uniqueKeysWithValues: photos.map { ($0.url.path, $0.rating) }),
            favorites: Dictionary(uniqueKeysWithValues: photos.map { ($0.url.path, $0.favorite) }),
            labels: Dictionary(uniqueKeysWithValues: photos.map { ($0.url.path, $0.colorLabel) })
        )
        do {
            try JSONEncoder().encode(doc).write(to: url, options: .atomic)
            status = "项目已保存"
        } catch { status = "保存失败：\(error.localizedDescription)" }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "oicproject") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let doc = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url))
            photos.removeAll(); selection.removeAll()
            importURLs(doc.paths.map(URL.init(fileURLWithPath:)))
            mode = doc.mode; hdrMode = doc.hdrMode; theme = doc.theme
            for photo in photos {
                photo.rating = doc.ratings[photo.url.path] ?? 0
                photo.favorite = doc.favorites[photo.url.path] ?? false
                photo.colorLabel = doc.labels[photo.url.path] ?? ""
                if doc.selection.contains(photo.url.path) { selection.insert(photo.id) }
            }
        } catch { status = "无法打开项目：\(error.localizedDescription)" }
    }

    func exportMetadataCSV() { ExportService.exportMetadata(selectedPhotos.isEmpty ? visiblePhotos : selectedPhotos) }
    func exportHistogramCSV() { ExportService.exportHistograms(selectedPhotos) }
    func exportPDF() { ExportService.exportPDF(selectedPhotos) }
    func exportCanvas(_ format: ExportService.CanvasFormat) { ExportService.exportCanvas(selectedPhotos, format: format) }
}
