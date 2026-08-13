import AppKit
import CoreGraphics
import Foundation

enum ZoomPreset: String, Codable, Equatable {
    case fit
    case actual
    case manual
}

/// A viewport is expressed in image coordinates rather than screen pixels.
/// That makes synchronized comparison stable when the compared images have
/// different dimensions or aspect ratios.
struct ViewportState: Equatable, Codable {
    var zoom: CGFloat = 1
    var center = CGPoint(x: 0.5, y: 0.5)
    var preset: ZoomPreset = .fit

    static let fit = ViewportState()

    mutating func reset() {
        self = .fit
    }
}

enum ViewportMath {
    static let minimumZoom: CGFloat = 0.25
    static let maximumZoom: CGFloat = 16

    static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(maximumZoom, max(minimumZoom, value.isFinite ? value : 1))
    }

    static func fitScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        return min(viewportSize.width / imageSize.width,
                   viewportSize.height / imageSize.height)
    }

    static func imageRect(imageSize: CGSize, viewport: CGRect, state: ViewportState) -> CGRect {
        let fit = fitScale(imageSize: imageSize, viewportSize: viewport.size)
        let scale = fit * clampedZoom(state.zoom)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: viewport.midX - state.center.x * size.width,
                      y: viewport.midY - state.center.y * size.height,
                      width: size.width,
                      height: size.height)
    }

    static func viewAlignment(_ alignment: CGAffineTransform, scale: CGFloat) -> CGAffineTransform {
        // Vision's translational registration is measured in source-image
        // pixels. Convert only the translation to view points; rotation and
        // scale remain part of the transform itself.
        var result = alignment
        result.tx *= scale
        result.ty *= scale
        return result
    }

    static func transformedBounds(imageSize: CGSize, viewport: CGRect,
                                  state: ViewportState,
                                  alignment: CGAffineTransform) -> CGRect {
        let rect = imageRect(imageSize: imageSize, viewport: viewport, state: state)
        let fit = fitScale(imageSize: imageSize, viewportSize: viewport.size)
        let scale = fit * clampedZoom(state.zoom)
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .concatenating(viewAlignment(alignment, scale: scale))
            .concatenating(CGAffineTransform(translationX: -rect.midX, y: -rect.midY))
        return rect.applying(transform)
    }

    /// Keeps the transformed image covering the viewport whenever it is large
    /// enough to do so, and centers it on an axis where it is smaller.
    static func clamped(_ proposed: ViewportState, imageSize: CGSize,
                        viewport: CGRect, alignment: CGAffineTransform) -> ViewportState {
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return .fit }

        var state = proposed
        state.zoom = clampedZoom(state.zoom)
        state.center.x = min(1, max(0, state.center.x.isFinite ? state.center.x : 0.5))
        state.center.y = min(1, max(0, state.center.y.isFinite ? state.center.y : 0.5))

        for _ in 0..<3 {
            let bounds = transformedBounds(imageSize: imageSize, viewport: viewport,
                                           state: state, alignment: alignment)
            let rect = imageRect(imageSize: imageSize, viewport: viewport, state: state)
            if bounds.width <= viewport.width {
                state.center.x = 0.5
            } else {
                if bounds.minX > viewport.minX {
                    state.center.x += (bounds.minX - viewport.minX) / max(1, rect.width)
                }
                if bounds.maxX < viewport.maxX {
                    state.center.x -= (viewport.maxX - bounds.maxX) / max(1, rect.width)
                }
            }
            if bounds.height <= viewport.height {
                state.center.y = 0.5
            } else {
                if bounds.minY > viewport.minY {
                    state.center.y += (bounds.minY - viewport.minY) / max(1, rect.height)
                }
                if bounds.maxY < viewport.maxY {
                    state.center.y -= (viewport.maxY - bounds.maxY) / max(1, rect.height)
                }
            }
            state.center.x = min(1, max(0, state.center.x))
            state.center.y = min(1, max(0, state.center.y))
        }
        if state.zoom <= 1.0001 { state.preset = .fit }
        return state
    }
}
