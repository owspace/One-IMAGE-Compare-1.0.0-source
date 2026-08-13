import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

@MainActor
enum ExportService {
    enum CanvasFormat {
        case png, jpeg, tiff16
        var name: String {
            switch self {
            case .png: return "对比画布.png"
            case .jpeg: return "对比画布.jpg"
            case .tiff16: return "对比画布.tiff"
            }
        }
        var type: UTType {
            switch self { case .png: return .png; case .jpeg: return .jpeg; case .tiff16: return .tiff }
        }
    }

    static func exportCanvas(_ items: [PhotoItem], format: CanvasFormat) {
        let images = items.compactMap { $0.displayPreview ?? $0.preview }
        guard !images.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.name
        panel.allowedContentTypes = [format.type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let columns = images.count <= 2 ? images.count : images.count <= 4 ? 2 : images.count <= 6 ? 3 : 4
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let cell = CGSize(width: 1200, height: 900)
        let canvasSize = CGSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows))
        let colorSpace = CGColorSpace(name: format == .tiff16 ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.sRGB)!
        let bits = format == .tiff16 ? 16 : 8
        let componentBytes = bits / 8
        guard let context = CGContext(
            data: nil, width: Int(canvasSize.width), height: Int(canvasSize.height),
            bitsPerComponent: bits, bytesPerRow: Int(canvasSize.width) * 4 * componentBytes,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                (format == .tiff16 ? CGBitmapInfo.byteOrder16Little.rawValue : CGBitmapInfo.byteOrder32Big.rawValue)
        ) else { return }
        context.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: canvasSize))
        for (index, image) in images.enumerated() {
            let column = index % columns
            let row = rows - 1 - index / columns
            let bounds = CGRect(x: CGFloat(column) * cell.width + 12, y: CGFloat(row) * cell.height + 12,
                                width: cell.width - 24, height: cell.height - 24)
            context.draw(image, in: fitRect(image: CGSize(width: image.width, height: image.height), in: bounds))
        }
        guard let result = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil)
        else { return }
        let properties: CFDictionary = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary
            : [:] as CFDictionary
        CGImageDestinationAddImage(destination, result, properties)
        CGImageDestinationFinalize(destination)
    }

    static func exportMetadata(_ items: [PhotoItem]) {
        guard !items.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "图片元数据.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let keys = Array(Set(items.flatMap { $0.metadata.rows.map { $0.0 } })).sorted()
        var rows = [["文件名"] + keys]
        for item in items {
            let dict = Dictionary(uniqueKeysWithValues: item.metadata.rows)
            rows.append([item.url.lastPathComponent] + keys.map { dict[$0] ?? "" })
        }
        writeCSV(rows, to: url)
    }

    static func exportHistograms(_ items: [PhotoItem]) {
        guard !items.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "直方图数据.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var rows = [["文件名", "Bin", "R", "G", "B", "Luminance"]]
        for item in items {
            for bin in 0..<256 {
                rows.append([item.url.lastPathComponent, "\(bin)", "\(item.histogram.red[bin])",
                             "\(item.histogram.green[bin])", "\(item.histogram.blue[bin])",
                             "\(item.histogram.luminance[bin])"])
            }
        }
        writeCSV(rows, to: url)
    }

    static func exportPDF(_ items: [PhotoItem]) {
        guard !items.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "图片对比报告.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let page = CGSize(width: 842, height: 595)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 22)]
        let bodyAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10)]
        for item in items {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSString(string: "One IMAGE 图片对比报告").draw(at: NSPoint(x: 36, y: 550), withAttributes: titleAttributes)
            NSString(string: item.url.lastPathComponent).draw(at: NSPoint(x: 36, y: 527), withAttributes: bodyAttributes)
            if let image = item.displayPreview ?? item.preview {
                let target = fitRect(image: CGSize(width: image.width, height: image.height),
                                     in: CGRect(x: 36, y: 170, width: 500, height: 340))
                context.draw(image, in: target)
            }
            var y: CGFloat = 500
            for row in item.metadata.rows.prefix(22) {
                NSString(string: "\(row.0)：\(row.1)").draw(at: NSPoint(x: 555, y: y), withAttributes: bodyAttributes)
                y -= 19
            }
            NSString(string: String(format: "高光剪切 %.2f%% · 阴影死黑 %.2f%%",
                                    item.histogram.highlightRatio * 100, item.histogram.shadowRatio * 100))
                .draw(at: NSPoint(x: 36, y: 140), withAttributes: bodyAttributes)
            NSString(string: "生成时间：\(Date().formatted())").draw(at: NSPoint(x: 36, y: 30), withAttributes: bodyAttributes)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        try? data.write(to: url, options: .atomic)
    }

    private static func writeCSV(_ rows: [[String]], to url: URL) {
        let content = rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator: "\n")
        try? ("\u{FEFF}" + content).write(to: url, atomically: true, encoding: .utf8)
    }
    private static func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    private static func fitRect(image: CGSize, in bounds: CGRect) -> CGRect {
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
