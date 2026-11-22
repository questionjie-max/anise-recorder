import AppKit
import Foundation

@MainActor
final class RegionSelectorController: NSObject {
    private var window: RegionSelectionWindow?
    private var completion: ((CaptureRegion?) -> Void)?
    private var keyMonitor: Any?

    func present(
        on screen: NSScreen,
        initialRegion: CaptureRegion?,
        completion: @escaping (CaptureRegion?) -> Void
    ) {
        cancel()
        let panel = RegionSelectionWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .readOnly
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        let view = RegionSelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size)
        )
        view.initialRegion = initialRegion
        view.onConfirm = { [weak self] region in
            self?.finish(region)
        }
        view.onCancel = { [weak self] in
            self?.finish(nil)
        }
        panel.contentView = view
        window = panel
        self.completion = completion

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        // 浮层必须真正出现在目标屏幕上：activate + orderFrontRegardless
        // 不依赖应用是否已经在前台，随后再抢 key 接收 Enter / Esc。
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(view)

        // 兜底：即使浮层因为窗口层级没有拿到 key，应用仍活动时
        // Enter / Esc 也能被这里接住。
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self, weak view] event in
            guard
                let self,
                self.window != nil,
                let view,
                view.window != nil
            else {
                return event
            }
            return view.handleKeyEvent(event) ? nil : event
        }
    }

    func cancel() {
        guard window != nil else { return }
        finish(nil)
    }

    private func finish(_ region: CaptureRegion?) {
        guard let panel = window else { return }
        window = nil
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panel.orderOut(nil)
        let completion = self.completion
        self.completion = nil
        completion?(region)
    }

    @objc private func applicationDidResignActive() {
        // 切到别的 App 时直接取消，避免留下一个看不见但还在等待
        // 输入的浮层；同一 App 内的窗口焦点变化不触发。
        cancel()
    }
}

private final class RegionSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class RegionSelectionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class RegionSelectionView: NSView {
    var onConfirm: ((CaptureRegion) -> Void)?
    var onCancel: (() -> Void)?

    var initialRegion: CaptureRegion? {
        didSet {
            guard !didApplyInitialRegion, let initialRegion else { return }
            didApplyInitialRegion = true
            let rect = initialRegion.screenRect(
                in: CGRect(origin: .zero, size: bounds.size)
            )
            selection = rect.intersection(bounds)
            updateConfirmButton()
            needsDisplay = true
        }
    }

    private enum DragMode {
        case creating(anchor: CGPoint)
        case moving(original: CGRect, start: CGPoint)
        case resizing(
            zone: RegionSelectionHitZone,
            original: CGRect,
            start: CGPoint
        )
    }

    private var selection: CGRect?
    private var dragMode: DragMode?
    private var didApplyInitialRegion = false
    private let confirmButton = RegionSelectionButton()
    private let cancelButton = RegionSelectionButton()

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        confirmButton.title = "确认区域"
        confirmButton.target = self
        confirmButton.action = #selector(confirmSelection)
        confirmButton.bezelStyle = .rounded
        confirmButton.controlSize = .large
        confirmButton.keyEquivalent = "\r"
        confirmButton.isEnabled = false
        addSubview(confirmButton)
        cancelButton.title = "取消"
        cancelButton.target = self
        cancelButton.action = #selector(cancelSelection)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        addSubview(cancelButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutButtons()
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        layoutButtons()
    }

    private func layoutButtons() {
        confirmButton.frame = CGRect(
            x: bounds.midX - 104,
            y: 24,
            width: 116,
            height: 34
        )
        cancelButton.frame = CGRect(
            x: bounds.midX + 20,
            y: 24,
            width: 84,
            height: 34
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        guard let selection else { return }
        let tolerance = RegionSelectionGeometry.hitTolerance
        addCursorRect(selection, cursor: .openHand)

        addCursorRect(
            CGRect(
                x: selection.minX - tolerance,
                y: selection.minY,
                width: tolerance * 2,
                height: selection.height
            ),
            cursor: .frameResize(position: .left, directions: .all)
        )
        addCursorRect(
            CGRect(
                x: selection.maxX - tolerance,
                y: selection.minY,
                width: tolerance * 2,
                height: selection.height
            ),
            cursor: .frameResize(position: .right, directions: .all)
        )
        addCursorRect(
            CGRect(
                x: selection.minX,
                y: selection.minY - tolerance,
                width: selection.width,
                height: tolerance * 2
            ),
            cursor: .frameResize(position: .bottom, directions: .all)
        )
        addCursorRect(
            CGRect(
                x: selection.minX,
                y: selection.maxY - tolerance,
                width: selection.width,
                height: tolerance * 2
            ),
            cursor: .frameResize(position: .top, directions: .all)
        )

        addCursorRect(
            CGRect(
                x: selection.minX - tolerance,
                y: selection.minY - tolerance,
                width: tolerance * 2,
                height: tolerance * 2
            ),
            cursor: .frameResize(position: .bottomLeft, directions: .all)
        )
        addCursorRect(
            CGRect(
                x: selection.maxX - tolerance,
                y: selection.maxY - tolerance,
                width: tolerance * 2,
                height: tolerance * 2
            ),
            cursor: .frameResize(position: .topRight, directions: .all)
        )
        addCursorRect(
            CGRect(
                x: selection.maxX - tolerance,
                y: selection.minY - tolerance,
                width: tolerance * 2,
                height: tolerance * 2
            ),
            cursor: .frameResize(position: .bottomRight, directions: .all)
        )
        addCursorRect(
            CGRect(
                x: selection.minX - tolerance,
                y: selection.maxY - tolerance,
                width: tolerance * 2,
                height: tolerance * 2
            ),
            cursor: .frameResize(position: .topLeft, directions: .all)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()

        guard let selection else {
            drawInstruction()
            return
        }

        NSColor.clear.setFill()
        selection.fill(using: .copy)

        NSColor.white.withAlphaComponent(0.92).setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1.5
        border.stroke()

        drawHandles(in: selection)

        let sizeSuffix = RegionSelectionGeometry.isConfirmable(selection)
            ? ""
            : " · 至少 64 × 64"
        let label = "\(Int(selection.width)) × \(Int(selection.height))\(sizeSuffix)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = label.size(withAttributes: attributes)
        let labelRect = CGRect(
            x: selection.minX,
            y: max(8, selection.minY - textSize.height - 16),
            width: textSize.width + 18,
            height: textSize.height + 10
        )
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(
            roundedRect: labelRect,
            xRadius: 7,
            yRadius: 7
        ).fill()
        label.draw(
            at: CGPoint(
                x: labelRect.minX + 9,
                y: labelRect.minY + 5
            ),
            withAttributes: attributes
        )

        drawInstruction()
    }

    private func drawHandles(in rect: CGRect) {
        let size: CGFloat = 7
        let points = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        NSColor.white.setFill()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        for point in points {
            let handle = CGRect(
                x: point.x - size / 2,
                y: point.y - size / 2,
                width: size,
                height: size
            )
            let path = NSBezierPath(
                roundedRect: handle,
                xRadius: 1.5,
                yRadius: 1.5
            )
            path.lineWidth = 1
            path.fill()
            path.stroke()
        }
    }

    private func drawInstruction() {
        let text = "拖拽框选 · 拖动内部移动 · 拖边角缩放 · 双击或 Enter 确认 · Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.82)
        ]
        let size = text.size(withAttributes: attributes)
        let rect = CGRect(
            x: bounds.midX - size.width / 2 - 15,
            y: bounds.maxY - 52,
            width: size.width + 30,
            height: 31
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15).fill()
        text.draw(
            at: CGPoint(x: rect.minX + 15, y: rect.minY + 8),
            withAttributes: attributes
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2, let selection, selection.contains(point) {
            if RegionSelectionGeometry.isConfirmable(selection) {
                confirmSelection()
            } else {
                NSSound.beep()
            }
            return
        }

        if let selection {
            let zone = RegionSelectionGeometry.hitZone(
                for: point,
                in: selection
            )
            switch zone {
            case .inside:
                dragMode = .moving(original: selection, start: point)
            case .outside:
                beginCreating(at: point)
            default:
                dragMode = .resizing(
                    zone: zone,
                    original: selection,
                    start: point
                )
            }
        } else {
            beginCreating(at: point)
        }
        needsDisplay = true
        updateConfirmButton()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case let .creating(anchor):
            selection = RegionSelectionGeometry.rect(
                from: anchor,
                to: point,
                clampedTo: bounds
            )
        case let .moving(original, start):
            selection = RegionSelectionGeometry.moved(
                original,
                by: CGSize(
                    width: point.x - start.x,
                    height: point.y - start.y
                ),
                clampedTo: bounds
            )
        case let .resizing(zone, original, start):
            selection = RegionSelectionGeometry.resized(
                original,
                zone: zone,
                by: CGSize(
                    width: point.x - start.x,
                    height: point.y - start.y
                ),
                clampedTo: bounds
            )
        case nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let selection, selection.width < 1 || selection.height < 1 {
            self.selection = nil
        }
        dragMode = nil
        needsDisplay = true
        updateConfirmButton()
        window?.invalidateCursorRects(for: self)
    }

    private func beginCreating(at point: CGPoint) {
        dragMode = .creating(anchor: point)
        selection = CGRect(origin: point, size: .zero)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyEvent(event) {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    @objc private func confirmSelection() {
        guard
            let selection,
            RegionSelectionGeometry.isConfirmable(selection),
            let region = RegionSelectionGeometry.normalizedRegion(
                for: selection,
                in: bounds
            )
        else {
            NSSound.beep()
            return
        }
        onConfirm?(region)
    }

    @objc private func cancelSelection() {
        onCancel?()
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76:
            confirmSelection()
            return true
        case 53:
            onCancel?()
            return true
        default:
            return false
        }
    }

    private func updateConfirmButton() {
        confirmButton.isEnabled = selection.map(
            RegionSelectionGeometry.isConfirmable
        ) ?? false
    }
}
