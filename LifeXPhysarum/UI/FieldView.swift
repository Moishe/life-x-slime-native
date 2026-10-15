import MetalKit
import SwiftUI

/// The simulation, drawn by Metal at display rate, with pattern placement
/// under the mouse.
struct FieldView: NSViewRepresentable {
    let model: SimulationModel
    let context: MetalContext

    func makeNSView(context: Context) -> FieldMTKView {
        FieldMTKView(model: model, context: self.context)
    }

    func updateNSView(_ view: FieldMTKView, context: Context) {}
}

final class FieldMTKView: MTKView, MTKViewDelegate {
    private let model: SimulationModel
    private let metal: MetalContext
    private var lastFrameTime: CFTimeInterval?
    // While dragging in paint mode: the state being painted and the last cell visited.
    private var paintState: Bool?
    private var lastDragCell: Cell?
    // Shown around the square field when the view isn't square.
    private var background = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    init(model: SimulationModel, context: MetalContext) {
        self.model = model
        metal = context
        super.init(frame: .zero, device: context.device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        framebufferOnly = true
        preferredFramesPerSecond = 120
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Simulation field")
        updateBackground()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dtMs = lastFrameTime.map { (now - $0) * 1000 } ?? 0
        lastFrameTime = now
        model.advance(dtMs: dtMs)

        guard let drawable = currentDrawable, let commandBuffer = metal.queue.makeCommandBuffer() else { return }
        commandBuffer.label = "display"
        let scale = drawableSize.width / max(bounds.width, 1)
        let rect = fieldRect(in: bounds.size)
        let viewport = MTLViewport(
            originX: rect.minX * scale, originY: rect.minY * scale,
            width: rect.width * scale, height: rect.height * scale, znear: 0, zfar: 1)
        model.encodeDisplay(into: commandBuffer, target: drawable.texture, viewport: viewport, background: background)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.underPageBackgroundColor.usingColorSpace(.sRGB) ?? .black
            background = MTLClearColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: 1)
        }
    }

    // MARK: Mouse

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(flipped(fieldRect(in: bounds.size)), cursor: .crosshair)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let cell = cell(for: event) else { return }
        paintState = model.click(cell)
        lastDragCell = cell
    }

    override func mouseDragged(with event: NSEvent) {
        let cell = cell(for: event)
        model.setHover(cell)
        guard let cell, let paintState, cell != lastDragCell else { return }
        model.paint(cell, alive: paintState)
        lastDragCell = cell
    }

    override func mouseUp(with event: NSEvent) {
        paintState = nil
        lastDragCell = nil
    }

    override func mouseMoved(with event: NSEvent) {
        model.setHover(cell(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        model.setHover(nil)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": model.rotate()
        case "t": model.settings.foodView.toggle()
        case " ": model.togglePlaying()
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): model.step()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Geometry

    /// The Life cell under the mouse, or nil outside the field.
    private func cell(for event: NSEvent) -> Cell? {
        let p = convert(event.locationInWindow, from: nil)
        let topLeft = CGPoint(x: p.x, y: bounds.height - p.y)
        return LifeXPhysarum.cell(at: topLeft, in: fieldRect(in: bounds.size), gridSize: model.settings.lifeSize)
    }

    /// A top-left-origin rect in this (bottom-left-origin) view's coordinates.
    private func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}
