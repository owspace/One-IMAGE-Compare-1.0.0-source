import AppKit
import SwiftUI

struct ImageCanvas: NSViewRepresentable {
    let image: CGImage?
    var imageID: UUID?
    var viewport: ViewportState
    var alignment: CGAffineTransform
    var background: NSColor = NSColor(white: 0.08, alpha: 1)
    /// Compare cells use the normal mouse wheel as a zoom gesture. The
    /// single-image viewer keeps wheel panning unless the user holds the
    /// usual command/option modifier.
    var scrollWheelZooms: Bool = false
    var onViewportChanged: ((ViewportState) -> Void)?

    func makeNSView(context: Context) -> EDRImageView {
        let view = EDRImageView()
        view.wantsLayer = true
        view.layer?.backgroundColor = background.cgColor
        view.layer?.masksToBounds = true
        view.layer?.wantsExtendedDynamicRangeContent = true
        view.imageID = imageID
        view.cgImage = image
        view.viewport = viewport
        view.alignment = alignment
        view.scrollWheelZooms = scrollWheelZooms
        view.onViewportChanged = onViewportChanged
        return view
    }

    func updateNSView(_ view: EDRImageView, context: Context) {
        view.onViewportChanged = onViewportChanged
        view.scrollWheelZooms = scrollWheelZooms
        view.layer?.backgroundColor = background.cgColor
        view.setContent(image: image, imageID: imageID, viewport: viewport, alignment: alignment)
    }
}

final class EDRImageView: NSView {
    var cgImage: CGImage?
    var imageID: UUID?
    var viewport = ViewportState.fit
    var alignment = CGAffineTransform.identity
    var scrollWheelZooms = false
    var onViewportChanged: ((ViewportState) -> Void)?

    private var dragOrigin: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    func setContent(image: CGImage?, imageID: UUID?, viewport: ViewportState,
                    alignment: CGAffineTransform) {
        let changedImage = self.imageID != imageID
        self.imageID = imageID
        self.cgImage = image
        self.alignment = alignment
        if changedImage { self.viewport = .fit }
        setViewport(viewport, notify: false)
        needsDisplay = true
    }

    func setViewport(_ proposed: ViewportState, notify: Bool = false) {
        guard let image = cgImage else {
            viewport = .fit
            return
        }
        let clamped = ViewportMath.clamped(proposed,
                                           imageSize: CGSize(width: image.width, height: image.height),
                                           viewport: bounds,
                                           alignment: alignment)
        let changed = clamped != viewport
        viewport = clamped
        needsDisplay = true
        if notify, changed { onViewportChanged?(viewport) }
    }

    func resetView() {
        setViewport(.fit, notify: true)
    }

    override func layout() {
        super.layout()
        setViewport(viewport, notify: false)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext,
              let image = cgImage,
              bounds.width > 0, bounds.height > 0 else { return }

        let imageSize = CGSize(width: image.width, height: image.height)
        let rect = ViewportMath.imageRect(imageSize: imageSize, viewport: bounds,
                                          state: viewport)
        let fit = ViewportMath.fitScale(imageSize: imageSize, viewportSize: bounds.size)
        let scale = fit * ViewportMath.clampedZoom(viewport.zoom)
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .concatenating(ViewportMath.viewAlignment(alignment, scale: scale))
            .concatenating(CGAffineTransform(translationX: -rect.midX, y: -rect.midY))

        context.saveGState()
        context.clip(to: bounds)
        context.concatenate(transform)
        context.interpolationQuality = viewport.zoom >= 1 ? .none : .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            resetView()
            return
        }
        dragOrigin = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let image = cgImage else { return }
        let current = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(x: current.x - origin.x, y: current.y - origin.y)
        let rect = ViewportMath.imageRect(imageSize: CGSize(width: image.width, height: image.height),
                                          viewport: bounds, state: viewport)
        guard rect.width > 0, rect.height > 0 else { return }

        var next = viewport
        next.preset = .manual
        next.center.x -= delta.x / rect.width
        next.center.y -= delta.y / rect.height
        dragOrigin = current
        setViewport(next, notify: true)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }

    override func magnify(with event: NSEvent) {
        let oldZoom = viewport.zoom
        let newZoom = ViewportMath.clampedZoom(oldZoom * (1 + event.magnification))
        guard oldZoom != newZoom else { return }
        let pointer = convert(event.locationInWindow, from: nil)
        applyZoom(newZoom, around: pointer)
    }

    override func scrollWheel(with event: NSEvent) {
        if scrollWheelZooms || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let oldZoom = viewport.zoom
            let factor = CGFloat(pow(1.1, Double(event.scrollingDeltaY / 10)))
            let newZoom = ViewportMath.clampedZoom(oldZoom * factor)
            guard oldZoom != newZoom else { return }
            let pointer = convert(event.locationInWindow, from: nil)
            applyZoom(newZoom, around: pointer)
            return
        }

        guard let image = cgImage, viewport.zoom > 1 else { return }
        let rect = ViewportMath.imageRect(imageSize: CGSize(width: image.width, height: image.height),
                                          viewport: bounds, state: viewport)
        guard rect.width > bounds.width || rect.height > bounds.height else { return }
        var next = viewport
        next.preset = .manual
        next.center.x -= event.scrollingDeltaX / max(1, rect.width)
        next.center.y -= event.scrollingDeltaY / max(1, rect.height)
        setViewport(next, notify: true)
    }

    private func applyZoom(_ newZoom: CGFloat, around pointer: CGPoint) {
        guard let image = cgImage else { return }
        let imageSize = CGSize(width: image.width, height: image.height)
        let oldRect = ViewportMath.imageRect(imageSize: imageSize, viewport: bounds,
                                             state: viewport)
        guard oldRect.width > 0, oldRect.height > 0 else { return }

        // Preserve the image point under the pointer. The subsequent clamp
        // only changes the result when the requested point would expose blank
        // space beyond an image edge.
        let normalized = CGPoint(x: (pointer.x - oldRect.minX) / oldRect.width,
                                 y: (pointer.y - oldRect.minY) / oldRect.height)
        var next = viewport
        next.zoom = newZoom
        next.preset = .manual
        let newRect = ViewportMath.imageRect(imageSize: imageSize, viewport: bounds,
                                             state: next)
        let desiredOrigin = CGPoint(x: pointer.x - normalized.x * newRect.width,
                                    y: pointer.y - normalized.y * newRect.height)
        next.center.x = (bounds.midX - desiredOrigin.x) / max(1, newRect.width)
        next.center.y = (bounds.midY - desiredOrigin.y) / max(1, newRect.height)
        setViewport(next, notify: true)
    }
}
