import SwiftUI

struct HistogramView: View {
    private static let maximumHDRStops = 4.0
    // Adobe's HDR histogram keeps a deliberately wide plotting area; the
    // labels and capability bar sit outside this plot. This avoids the tall,
    // narrow graph that was previously produced in the 300 px inspector.
    private static let adobePlotAspectRatio: CGFloat = 2.65

    let histogram: HistogramData
    let channel: String
    let contentHeadroomEV: Double?
    let displayHeadroomEV: Double?
    @State private var showsClipping = false

    init(histogram: HistogramData, channel: String,
         contentHeadroomEV: Double? = nil, displayHeadroomEV: Double? = nil,
         showsDynamicRange: Bool = true,
         displayDomain: HistogramData.Domain? = nil) {
        var value = histogram
        value.domain = displayDomain ?? (showsDynamicRange ? histogram.domain : .sdr)
        self.histogram = value
        self.channel = channel
        self.contentHeadroomEV = contentHeadroomEV
        self.displayHeadroomEV = displayHeadroomEV
    }

    private var isHDR: Bool { histogram.domain == .hdr }
    private var contentStops: Double {
        min(Self.maximumHDRStops, max(0, contentHeadroomEV ?? 0))
    }
    private var displayStops: Double {
        min(Self.maximumHDRStops, max(0, displayHeadroomEV ?? 0))
    }
    private var selectedBins: [Int] {
        switch channel {
        case "R": return histogram.red
        case "G": return histogram.green
        case "B": return histogram.blue
        case "亮度": return histogram.luminance
        default: return []
        }
    }

    private var displayHighlightRatio: Double {
        if histogram.displayHighlightClipRatio > 0 { return histogram.displayHighlightClipRatio }
        guard isHDR, histogram.sampleCount > 0 else { return histogram.highlightClipRatio }
        let firstUnsupported = min(255, max(128,
            128 + Int((displayStops / Self.maximumHDRStops * 127).rounded())))
        let count = histogram.red[firstUnsupported...].reduce(0, +) +
            histogram.green[firstUnsupported...].reduce(0, +) +
            histogram.blue[firstUnsupported...].reduce(0, +)
        let denominator = max(1, histogram.sampleCount * 3)
        return Double(count) / Double(denominator)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .aspectRatio(Self.adobePlotAspectRatio, contentMode: .fit)
                .overlay {
                    ZStack {
                        Canvas { context, size in
                    drawBackground(in: &context, size: size)
                    if channel == "RGB" {
                        let maxValue = max(histogram.red.max() ?? 0,
                                           max(histogram.green.max() ?? 0,
                                               histogram.blue.max() ?? 0))
                        draw(histogram.red, color: .red, maxValue: maxValue,
                             in: &context, size: size)
                        draw(histogram.green, color: .green, maxValue: maxValue,
                             in: &context, size: size)
                        draw(histogram.blue, color: .blue, maxValue: maxValue,
                             in: &context, size: size)
                    } else {
                        draw(selectedBins, color: channel == "亮度" ? .white : channelColor,
                             maxValue: selectedBins.max() ?? 0, in: &context, size: size)
                    }
                    if showsClipping { drawClippingOverlay(in: &context, size: size) }
                        }
                        if isHDR && displayStops < Self.maximumHDRStops - 0.001 {
                            Button { showsClipping.toggle() } label: {
                                Image(systemName: showsClipping ? "eye" : "eye.slash")
                                    .font(.system(size: 19, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("点击显示/隐藏裁切提示")
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(.top, 10)
                            .padding(.trailing, 10)
                        }
                        if !histogram.isValid {
                            Text(histogram.sampleStatus)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }

            HStack(spacing: 0) {
                Text("SDR").frame(maxWidth: .infinity)
                if isHDR { Text("HDR").frame(maxWidth: .infinity) }
            }
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white.opacity(0.72))
            .frame(height: 23)
            .background(.black.opacity(0.22))

            if isHDR { capabilityBar }
        }
        .background(Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1)))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var channelColor: Color {
        switch channel { case "R": return .red; case "G": return .green; default: return .blue }
    }

    private var capabilityBar: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - 8)
            let sdrWidth = width * 0.5
            let supportedWidth = sdrWidth + (width - sdrWidth) * CGFloat(displayStops / Self.maximumHDRStops)
            ZStack(alignment: .leading) {
                Rectangle().fill(.red.opacity(0.86))
                Rectangle().fill(.yellow.opacity(0.92)).frame(width: supportedWidth)
                Path { path in
                    path.move(to: CGPoint(x: sdrWidth, y: 0))
                    path.addLine(to: CGPoint(x: sdrWidth, y: proxy.size.height))
                    for stop in 1..<4 {
                        let x = sdrWidth + (width - sdrWidth) * CGFloat(stop) / 4
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    }
                }
                .stroke(.black.opacity(0.48), lineWidth: 1)
                if contentStops > 0 {
                    Rectangle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 1)
                        .offset(x: sdrWidth + (width - sdrWidth) * CGFloat(contentStops / Self.maximumHDRStops))
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 7)
        .background(.black.opacity(0.3))
    }

    private func drawBackground(in context: inout GraphicsContext, size: CGSize) {
        let plotHeight = max(1, size.height - 4)
        if isHDR {
            let split = size.width * 0.5
            let hdrWidth = size.width - split
            let stopWidth = hdrWidth / CGFloat(Self.maximumHDRStops)
            context.fill(Path(CGRect(x: 0, y: 0, width: split, height: plotHeight)),
                         with: .color(Color(nsColor: NSColor(calibratedWhite: 0.25, alpha: 1))))
            context.fill(Path(CGRect(x: split, y: 0, width: hdrWidth, height: plotHeight)),
                         with: .color(Color(nsColor: NSColor(calibratedRed: 0.23, green: 0.21, blue: 0.17, alpha: 1))))

            let displayX = split + stopWidth * CGFloat(displayStops)
            if displayX < size.width {
                context.fill(Path(CGRect(x: displayX, y: 0,
                                         width: size.width - displayX, height: plotHeight)),
                             with: .color(.red.opacity(0.12)))
            }

            var divider = Path()
            divider.move(to: CGPoint(x: split, y: 0))
            divider.addLine(to: CGPoint(x: split, y: plotHeight))
            context.stroke(divider, with: .color(.white.opacity(0.44)), lineWidth: 2)

            for stop in 1..<4 {
                var guide = Path()
                let x = split + stopWidth * CGFloat(stop)
                guide.move(to: CGPoint(x: x, y: 0))
                guide.addLine(to: CGPoint(x: x, y: plotHeight))
                context.stroke(guide, with: .color(.white.opacity(0.17)),
                               style: StrokeStyle(lineWidth: 1, dash: [7, 6]))
            }

            if contentStops > 0 {
                var marker = Path()
                marker.move(to: CGPoint(x: split + stopWidth * CGFloat(contentStops), y: 0))
                marker.addLine(to: CGPoint(x: split + stopWidth * CGFloat(contentStops), y: plotHeight))
                context.stroke(marker, with: .color(.yellow.opacity(0.8)), lineWidth: 1)
            }
        } else {
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: plotHeight)),
                         with: .color(Color(nsColor: NSColor(calibratedWhite: 0.25, alpha: 1))))
        }

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: plotHeight))
        baseline.addLine(to: CGPoint(x: size.width, y: plotHeight))
        context.stroke(baseline, with: .color(.white.opacity(0.84)), lineWidth: 2)
    }

    private func draw(_ bins: [Int], color: Color, maxValue: Int,
                      in context: inout GraphicsContext, size: CGSize) {
        guard !bins.isEmpty, maxValue > 0 else { return }
        let plotHeight = max(1, size.height - 8)
        let denominator = log(Double(maxValue) + 1)
        var path = Path()
        for index in bins.indices {
            let x = CGFloat(index) / CGFloat(max(1, bins.count - 1)) * size.width
            let normalized = log(Double(bins[index]) + 1) / denominator
            let y = size.height - 5 - CGFloat(normalized) * plotHeight
            if path.isEmpty { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(color.opacity(0.94)), lineWidth: 1.35)
    }

    private func drawClippingOverlay(in context: inout GraphicsContext, size: CGSize) {
        let shadowWidth = min(size.width * 0.16, max(5, size.width * CGFloat(histogram.shadowRatio)))
        context.fill(Path(CGRect(x: 0, y: 0, width: shadowWidth, height: size.height)),
                     with: .color(.blue.opacity(0.16)))
        if isHDR {
            let split = size.width * 0.5
            let hdrWidth = size.width - split
            let unsupportedX = split + hdrWidth * CGFloat(displayStops / Self.maximumHDRStops)
            if unsupportedX < size.width {
                context.fill(Path(CGRect(x: unsupportedX, y: 0,
                                         width: size.width - unsupportedX, height: size.height)),
                             with: .color(.red.opacity(0.16)))
            }
        } else {
            let highlightRatio = displayHighlightRatio
            let highlightWidth = min(size.width * 0.16, max(5, size.width * CGFloat(highlightRatio)))
            context.fill(Path(CGRect(x: size.width - highlightWidth, y: 0,
                                     width: highlightWidth, height: size.height)),
                         with: .color(.red.opacity(0.16)))
        }
    }
}
