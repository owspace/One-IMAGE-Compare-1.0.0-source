import SwiftUI

struct SkinToneIndicatorView: View {
    let stats: SkinToneStats

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack {
                    Canvas { context, size in
                        drawScope(in: &context, size: size)
                    }
                    .background(Color.black.opacity(0.28))
                    .clipShape(Circle())
                    Text("R").font(.caption2.bold()).foregroundStyle(.white.opacity(0.7))
                        .offset(x: min(proxy.size.width, proxy.size.height) * 0.42)
                    Text("B").font(.caption2.bold()).foregroundStyle(.white.opacity(0.7))
                        .offset(y: min(proxy.size.width, proxy.size.height) * 0.42)
                }
                .frame(width: min(proxy.size.width, proxy.size.height),
                       height: min(proxy.size.width, proxy.size.height))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 146)

            VStack(alignment: .leading, spacing: 5) {
                metric("候选肤色占比", stats.candidateRatio.mapPercent)
                metric("平均肤色色相", stats.meanHueDegrees.map { String(format: "%.1f°", $0) } ?? "无肤色信号")
                metric("偏离肤色线", stats.lineDeviationDegrees.map { String(format: "%.1f°", $0) } ?? "无肤色信号")
                metric("色相离散度", stats.hueStdDevDegrees.map { String(format: "%.1f°", $0) } ?? "无肤色信号")
                metric("平均饱和度", stats.meanSaturation.map { String(format: "%.1f%%", $0 * 100) } ?? "无肤色信号")
                if stats.faceAnalysisState != "未分析" {
                    Divider().opacity(0.5)
                    Text("人脸区域").font(.caption.bold())
                    metric("分析状态", stats.faceAnalysisState)
                    metric("检测到人脸", "\(stats.faceCount) 张")
                    metric("人脸肤色候选占比", stats.faceCandidateRatio.mapPercent)
                    metric("人脸平均色相", stats.faceMeanHueDegrees.map { String(format: "%.1f°", $0) } ?? "无肤色信号")
                    metric("人脸偏离肤色线", stats.faceLineDeviationDegrees.map { String(format: "%.1f°", $0) } ?? "无肤色信号")
                }
            }
            .font(.caption)
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
    }

    private func drawScope(in context: inout GraphicsContext, size: CGSize) {
        let diameter = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = diameter * 0.40
        let maxValue = max(0.0001, stats.vectorscopeBins.max() ?? 0)
        let maxSkinValue = max(0.0001, stats.skinVectorscopeBins.max() ?? 0)

        for fraction in [0.33, 0.66, 1.0] {
            let circle = Path(ellipseIn: CGRect(x: center.x - radius * fraction,
                                                 y: center.y - radius * fraction,
                                                 width: radius * fraction * 2,
                                                 height: radius * fraction * 2))
            context.stroke(circle, with: .color(.white.opacity(0.18)), lineWidth: 1)
        }
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - radius, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - radius))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        context.stroke(cross, with: .color(.white.opacity(0.18)), lineWidth: 1)

        for angleIndex in 0..<72 {
            let angle = Double(angleIndex) / 72 * 2 * Double.pi
            for radiusIndex in 0..<24 {
                let value = stats.vectorscopeBins[angleIndex * 24 + radiusIndex]
                guard value > 0 else { continue }
                let radial = radius * (Double(radiusIndex) + 0.5) / 24
                let point = CGPoint(x: center.x + cos(angle) * radial,
                                    y: center.y - sin(angle) * radial)
                let dot = CGRect(x: point.x - 1.2, y: point.y - 1.2, width: 2.4, height: 2.4)
                let color = Color(hue: angle / (2 * Double.pi), saturation: 0.78,
                                  brightness: min(1, 0.25 + value / maxValue))
                context.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.42)))
            }
            for radiusIndex in 0..<24 {
                let value = stats.skinVectorscopeBins[angleIndex * 24 + radiusIndex]
                guard value > 0 else { continue }
                let radial = radius * (Double(radiusIndex) + 0.5) / 24
                let point = CGPoint(x: center.x + cos(angle) * radial,
                                    y: center.y - sin(angle) * radial)
                let dot = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
                context.fill(Path(ellipseIn: dot), with: .color(.yellow.opacity(0.45 + min(0.5, value / maxSkinValue))))
            }
        }

        let skinAngle = -stats.lineAngleDegrees * Double.pi / 180
        var line = Path()
        line.move(to: CGPoint(x: center.x - cos(skinAngle) * radius,
                              y: center.y + sin(skinAngle) * radius))
        line.addLine(to: CGPoint(x: center.x + cos(skinAngle) * radius,
                                 y: center.y - sin(skinAngle) * radius))
        context.stroke(line, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
                     with: .color(.white))

        if let faceHue = stats.faceMeanHueDegrees, let faceSaturation = stats.faceMeanSaturation {
            let faceAngle = faceHue * Double.pi / 180
            let faceRadius = radius * min(1, max(0, faceSaturation))
            let facePoint = CGPoint(x: center.x + cos(faceAngle) * faceRadius,
                                    y: center.y - sin(faceAngle) * faceRadius)
            let marker = CGRect(x: facePoint.x - 5, y: facePoint.y - 5, width: 10, height: 10)
            context.stroke(Path(ellipseIn: marker), with: .color(.orange), lineWidth: 2)
        }
    }
}

private extension Double {
    var mapPercent: String { String(format: "%.2f%%", self * 100) }
}
