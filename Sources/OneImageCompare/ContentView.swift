import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: PhotoStore
    @State private var thumbnailSize: CGFloat = 150

    var body: some View {
        ZStack {
            Color(nsColor: NSColor(white: store.theme == .neutral ? 0.5 : (store.theme == .dark ? 0.12 : 0.92), alpha: 1))
                .ignoresSafeArea()
            VStack(spacing: 0) {
                toolbar
                Divider()
                HStack(spacing: 0) {
                    if store.sidebarVisible { sidebar.frame(width: 220) }
                    if store.sidebarVisible { Divider() }
                    mainContent
                    if store.inspectorVisible { Divider(); inspector.frame(width: 300) }
                }
                Divider()
                statusBar
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let item = try? await provider.loadItem(forTypeIdentifier: "public.file-url"),
                       let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                await MainActor.run { store.importURLs(urls) }
            }
            return true
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { store.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
            Button("文件") { store.openFiles() }
            Button("文件夹") { store.openFolder() }
            Divider().frame(height: 22)
            Picker("", selection: $store.mode) {
                Label("浏览", systemImage: "square.grid.2x2").tag(AppMode.browser)
                Label("单图", systemImage: "photo").tag(AppMode.viewer)
                Label("对比", systemImage: "rectangle.split.3x1").tag(AppMode.compare)
            }.pickerStyle(.segmented).frame(width: 230)
            displayModeTabs
            if store.inspectorPhoto != nil {
                Button {
                    store.toggleEffectAnalysis()
                } label: {
                    Label("效果分析", systemImage: store.effectAnalysisVisible ? "chart.xyaxis.line" : "waveform.path.ecg")
                }
                .help("打开 SDR / HDR 效果分析")
            }
            if store.mode != .browser {
                Button("适合") { store.resetView() }
                    .help("重置为适合窗口并居中")
            }
            if store.mode == .compare {
                Button("自动对齐") { store.autoAlign() }
                Button("重置对齐") { store.resetAlignment() }
                Toggle("同步视口", isOn: $store.syncPan)
                    .toggleStyle(.checkbox)
                zoomControl
            } else if store.mode == .viewer {
                zoomControl
            }
            Spacer()
            Menu {
                Button("对比画布 PNG") { store.exportCanvas(.png) }
                Button("对比画布 JPEG") { store.exportCanvas(.jpeg) }
                Button("对比画布 16-bit TIFF") { store.exportCanvas(.tiff16) }
                Divider()
                Button("元数据 CSV") { store.exportMetadataCSV() }
                Button("直方图 CSV") { store.exportHistogramCSV() }
                Button("PDF 报告") { store.exportPDF() }
                Button("保存项目") { store.saveProject() }
            } label: { Label("导出", systemImage: "square.and.arrow.up") }
            Button { store.inspectorVisible.toggle() } label: { Image(systemName: "sidebar.right") }
        }
        .buttonStyle(.bordered)
        .padding(8)
        .background(.ultraThinMaterial)
    }

    private var zoomControl: some View {
        HStack(spacing: 5) {
            Slider(value: Binding(get: { store.zoom }, set: { store.setToolbarZoom($0) }),
                   in: ViewportMath.minimumZoom...ViewportMath.maximumZoom)
                .frame(width: 110)
            Text(store.zoom <= 1.0001 ? "适合" : "\(Int(store.zoom * 100))%")
                .monospacedDigit().frame(width: 44)
        }
    }

    private var displayModeTabs: some View {
        HStack(spacing: 0) {
            ForEach(HDRMode.allCases) { option in
                Button {
                    if store.hdrMode != option { store.hdrMode = option }
                } label: {
                    Text(option == .hdr ? "HDR" : "SDR")
                        .font(.caption.weight(.semibold))
                        .frame(width: 58, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.hdrMode == option ? .white : .secondary)
                .background(store.hdrMode == option ? Color.accentColor : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .help(option == .hdr ? "显示 HDR / Gain Map" : "显示 SDR 基础图")
            }
        }
        .padding(2)
        .background(.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("照片").font(.headline)
            TextField("搜索文件名", text: $store.query)
            Picker("排序", selection: $store.sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("格式", selection: $store.formatFilter) {
                ForEach(store.availableFormats, id: \.self) { Text($0).tag($0) }
            }
            Picker("动态范围", selection: $store.hdrFilter) {
                ForEach(["全部", "HDR", "SDR"], id: \.self) { Text($0).tag($0) }
            }
            Divider()
            Button("选择前 8 张") { store.selectVisible(upTo: 8) }
            Button("进入对比（\(store.selection.count)）") { store.enterCompare() }
                .disabled(!(2...8).contains(store.selection.count))
            Divider()
            Text("支持").font(.caption.bold())
            Text("JPEG · HEIC/HEIF · PNG · TIFF · DNG · AVIF · ProRAW · 系统兼容 RAW")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(12)
    }

    @ViewBuilder private var mainContent: some View {
        switch store.mode {
        case .browser: browser
        case .viewer: viewer
        case .compare: compare
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            if store.photos.isEmpty {
                ContentUnavailableView("打开照片开始", systemImage: "photo.on.rectangle.angled",
                                       description: Text("支持拖放文件；最多选择 8 张进入对比"))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 8)], spacing: 8) {
                        ForEach(store.visiblePhotos) { item in
                            thumbnailCell(item)
                        }
                    }.padding(10)
                }
                HStack {
                    Image(systemName: "photo")
                    Slider(value: $thumbnailSize, in: 90...260).frame(width: 130)
                    Spacer()
                    Text("选择 \(store.selection.count) 张（对比最多 8 张）")
                }.font(.caption).padding(7).background(.ultraThinMaterial)
            }
        }
    }

    private func thumbnailCell(_ item: PhotoItem) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.28))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image = item.thumbnail {
                            Image(nsImage: image).resizable().scaledToFit().padding(3)
                        } else if item.error != nil {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                        } else { ProgressView().controlSize(.small) }
                    }
                if item.metadata.hdr.isHDR {
                    Text("HDR").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.orange).foregroundStyle(.black).clipShape(Capsule()).padding(5)
                }
            }
            Text(item.url.lastPathComponent).font(.caption).lineLimit(1)
        }
        .padding(4)
        .background(store.selection.contains(item.id) ? Color.accentColor.opacity(0.55) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture(count: 2).onEnded { store.showViewer(item) })
        .onTapGesture { store.selectThumbnail(item, modifiers: NSEvent.modifierFlags) }
        .contextMenu {
            Button("设为基准图") { store.referenceID = item.id }
            Button(item.favorite ? "取消收藏" : "收藏") { item.favorite.toggle() }
            Menu("评分") { ForEach(0...5, id: \.self) { value in Button("\(value) 星") { item.rating = value } } }
        }
    }

    private var viewer: some View {
        Group {
            if let item = store.inspectorPhoto {
                ZStack {
                    ImageCanvas(image: item.displayPreview, imageID: item.id,
                                viewport: store.viewport(for: item.id), alignment: item.alignment,
                                onViewportChanged: { store.updateViewport($0, for: item.id) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    if item.loading { ProgressView("正在解码完整预览…").padding().background(.regularMaterial).cornerRadius(8) }
                }
                .background(Color.black)
                .clipped()
                .onAppear { store.loadPreview(item) }
            } else {
                ContentUnavailableView("未选择照片", systemImage: "photo")
            }
        }
    }

    private var compare: some View {
        GeometryReader { geometry in
            let items = store.selectedPhotos
            let columns = compareColumns(count: items.count)
            let rows = max(1, Int(ceil(Double(max(items.count, 1)) / Double(columns))))
            let spacing: CGFloat = 4
            let cellWidth = max(180, (geometry.size.width - CGFloat(columns - 1) * spacing - 8) / CGFloat(columns))
            let cellHeight = max(150, (geometry.size.height - CGFloat(rows - 1) * spacing - 8) / CGFloat(rows))
            ScrollView([.vertical, .horizontal]) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: columns), spacing: spacing) {
                    ForEach(items) { item in
                        compareCell(item, width: cellWidth, height: cellHeight)
                    }
                }
                .padding(4)
            }
        }
    }

    private func compareCell(_ item: PhotoItem, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ImageCanvas(image: item.displayPreview, imageID: item.id,
                        viewport: store.viewport(for: item.id), alignment: item.alignment,
                        scrollWheelZooms: true,
                        onViewportChanged: { store.updateViewport($0, for: item.id) })
                .frame(width: width, height: height)
                .background(Color.black)
                .clipped()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if store.referenceID == item.id { Text("基准") }
                    Text(item.url.lastPathComponent).lineLimit(1)
                }
                if let confidence = item.alignmentConfidence {
                    Text(confidence > 0 ? "已对齐" : "对齐失败")
                        .foregroundStyle(confidence > 0 ? .green : .red)
                }
            }
            .font(.caption)
            .padding(5)
            .background(.black.opacity(0.62))
            .foregroundStyle(.white)
            if item.loading { ProgressView().padding(12).frame(width: width, height: height, alignment: .center) }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay { RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.16), lineWidth: 1) }
        .contentShape(Rectangle())
        .contextMenu { Button("设为基准图") { store.referenceID = item.id } }
        .onTapGesture {
            store.selectedInspectorID = item.id
            store.zoom = store.viewport(for: item.id).zoom
        }
        .onAppear { store.loadPreview(item) }
    }

    private func compareColumns(count: Int) -> Int {
        switch count { case 0...2: return max(1, count); case 3...4: return 2; case 5...6: return 3; default: return 4 }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            if let item = store.inspectorPhoto {
                histogramPanel(item)
                if store.effectAnalysisVisible {
                    EffectAnalysisPanel(item: item)
                } else {
                    Picker("", selection: $store.inspectorTab) {
                        ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).padding(10)
                    if store.inspectorTab == .gainMap {
                        gainMapInspector(item)
                    } else {
                        photoInfoInspector(item)
                    }
                }
            } else {
                ContentUnavailableView("无信息", systemImage: "info.circle")
            }
        }.background(.ultraThinMaterial)
    }

    private func gainMapInspector(_ item: PhotoItem) -> some View {
        let info = item.metadata.gainMap
        let display = HDRDisplayInfo.current
        let weight = info.weight(for: display).map { String(format: "%.2f", $0) } ?? "无可靠数据"
        var remaining = info.remainingRows()
        if let resolution = info.resolutionRow { remaining.append(resolution) }
        remaining.append(("Gain Map Type", info.kind))
        remaining.append(("Gain Map Weight (W)", weight))
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(info.available ? info.kind : "未检测到 Gain Map").font(.headline)
                    Spacer()
                    Text(info.available ? "已检测" : "SDR/普通图像").font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.thinMaterial).clipShape(Capsule())
                }
                if !info.available {
                    Text("ImageIO 未发现 ISO 21496-1 或 Apple HDR Gain Map 辅助数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if info.available {
                    inspectorSection("① 当前 API / 屏幕信息", display.rows)
                    inspectorSection("② Headroom / Gain Map 参数", info.headroomRows(hdrHeadroom: item.metadata.hdr.headroom))
                    inspectorSection("③ 其余 Gain Map 信息", remaining)
                } else {
                    inspectorSection("① 当前 API / 屏幕信息", display.rows)
                }
            }.padding(10)
        }
    }

    private func histogramPanel(_ item: PhotoItem) -> some View {
        let contentHeadroomEV = item.histogram.contentHeadroomEV
            ?? item.metadata.hdr.headroom.map { max(0, log2(max(1, $0))) }
            ?? item.metadata.gainMap.alternateHDRHeadroom.map { max(0, $0) }
        let displayHeadroomEV = HDRDisplayInfo.current.headroomEV
        return DisclosureGroup(isExpanded: $store.histogramExpanded) {
            VStack(spacing: 0) {
                HistogramView(histogram: item.histogram, channel: store.histogramChannel,
                             contentHeadroomEV: contentHeadroomEV,
                             displayHeadroomEV: displayHeadroomEV,
                             showsDynamicRange: store.hdrMode == .hdr,
                             displayDomain: store.hdrMode == .hdr ? .hdr : .sdr)
                Picker("通道", selection: $store.histogramChannel) {
                    ForEach(["RGB", "亮度", "R", "G", "B"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).padding(.top, 8)
            }
        } label: {
            HStack {
                Text("直方图").font(.subheadline.bold())
                Spacer()
                Text(store.hdrMode == .hdr ? "当前：HDR" : "当前：SDR")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, store.histogramExpanded ? 8 : 10)
    }

    private func photoInfoInspector(_ item: PhotoItem) -> some View {
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(item.metadata.hdr.kind).font(.headline)
                        Spacer()
                        Text(item.metadata.hdr.confidence + "置信度").font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.thinMaterial).clipShape(Capsule())
                    }
                    ForEach(Array(item.metadata.sections.enumerated()), id: \.offset) { _, section in
                        inspectorSection(section.0, section.1)
                    }
                }.padding(10)
            }
        }
    }

    private func inspectorSection(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.bold())
            metadataRows(rows)
        }
        .padding(9)
        .background(.black.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func metadataRows(_ rows: [(String, String)]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            HStack(alignment: .top) {
                Text(row.0).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                Text(row.1).textSelection(.enabled)
                Spacer(minLength: 0)
            }.font(.caption)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(store.status).lineLimit(1)
            Spacer()
            if store.isWorking {
                ProgressView(value: store.loadingProgress).frame(width: 150)
                Button("取消") { /* cooperative tasks finish quickly */ }.disabled(true)
            }
            Text("\(store.visiblePhotos.count) / \(store.photos.count)")
        }.font(.caption).padding(.horizontal, 9).frame(height: 27).background(.ultraThinMaterial)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: PhotoStore
    var body: some View {
        Form {
            Picker("界面外观", selection: $store.theme) {
                ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("默认显示右侧信息面板", isOn: $store.inspectorVisible)
            Text("中性灰模式使用 50% 灰观察环境；图像色彩由 ColorSync、ImageIO 与 Core Image 管理。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 440)
    }
}
