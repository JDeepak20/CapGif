//
//  RegionSelector.swift
//  CapGif
//
//  Created by Deepak Joshi on 23/10/25.
//

import Foundation
import AppKit

/// Presents a borderless, full-screen overlay window that lets the user drag a rectangle.
/// Returns the rect in GLOBAL screen coordinates (points, origin bottom-left).
enum RegionSelector {
    static func present(onSelection: @escaping (CGRect) -> Void,
                        onCancel: @escaping () -> Void,
                        onStart: @escaping () -> Void,
                        onStop: @escaping () -> Void) {
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }

        let window = NSWindow(
            contentRect: union,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false

        let view = SelectionCaptureView(frame: NSRect(origin: .zero, size: union.size))
        view.onDone = { rect in
            onSelection(rect)
        }
        view.onCancel = {
            window.orderOut(nil)
            onCancel()
        }
        view.onStart = {
            onStart()
        }
        view.onStop = {
            window.orderOut(nil)
            onStop()
        }

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class SelectionCaptureView: NSView {
    var onDone: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    private var startLocal: CGPoint?
    private var currentLocal: CGPoint?
    private var startScreen: CGPoint?
    private var currentScreen: CGPoint?
    private var stopPanel: StopFloatingPanel?

    private lazy var startButton: NSButton = {
        let button = NSButton(title: "Start", target: self, action: #selector(startTapped))
        button.bezelStyle = .rounded
        button.isHidden = true
        button.isEnabled = true
        return button
    }()

    private lazy var stopButton: NSButton = {
        let button = NSButton(title: "Stop", target: self, action: #selector(stopTapped))
        button.bezelStyle = .rounded
        button.isHidden = true
        button.isEnabled = false
        return button
    }()

    private var isRecording = false {
        didSet { updateButtonStates() }
    }

    private var selectionRectInView: NSRect? {
        guard let a = startLocal, let b = currentLocal else { return nil }
        return NSRect(x: min(a.x, b.x),
                      y: min(a.y, b.y),
                      width: abs(a.x - b.x),
                      height: abs(a.y - b.y))
    }

    private var selectionRectOnScreen: CGRect? {
        guard let a = startScreen, let b = currentScreen else { return nil }
        return CGRect(x: min(a.x, b.x),
                      y: min(a.y, b.y),
                      width: abs(a.x - b.x),
                      height: abs(a.y - b.y))
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.20).cgColor
        addSubview(startButton)
        addSubview(stopButton)
        addEscapeMonitor()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        guard !isRecording else { return }
        guard let window else { return }

        let windowPoint = event.locationInWindow
        let local = convert(windowPoint, from: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)

        startLocal = local
        currentLocal = local
        startScreen = screenPoint
        currentScreen = screenPoint
        isRecording = false
        hideControlButtons()
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !isRecording else { return }
        guard let window else { return }

        let windowPoint = event.locationInWindow
        currentLocal = convert(windowPoint, from: nil)
        currentScreen = window.convertPoint(toScreen: windowPoint)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !isRecording else { return }
        guard let window else { return }

        let windowPoint = event.locationInWindow
        currentLocal = convert(windowPoint, from: nil)
        currentScreen = window.convertPoint(toScreen: windowPoint)

        guard selectionRectInView != nil,
              let rectOnScreen = selectionRectOnScreen else {
            hideControlButtons()
            onCancel?()
            return
        }

        if rectOnScreen.width < 3 || rectOnScreen.height < 3 {
            hideControlButtons()
            onCancel?()
        } else {
            onDone?(rectOnScreen)
            showControlButtons()
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // dim everything
        NSColor.black.withAlphaComponent(0.20).setFill()
        dirtyRect.fill()

        if let r = selectionRectInView {
            // clear the selection area
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(rect: r).fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            NSColor.systemRed.setStroke()
            let path = NSBezierPath(rect: r)
            path.lineWidth = 2
            path.stroke()
        }
    }

    // ESC to cancel
    private var escMonitor: Any?
    private func addEscapeMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            if e.keyCode == 53 {
                if self.isRecording {
                    return e
                }
                self.hideControlButtons()
                self.onCancel?()
                return nil
            }
            return e
        }
    }
    deinit {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        dismissStopPanel()
    }

    private func presentStopPanel(for rect: CGRect) {
        dismissStopPanel()
        let panel = StopFloatingPanel { [weak self] in
            self?.handleStop()
        }
        stopPanel = panel
        panel.show(relativeTo: rect)
    }

    private func dismissStopPanel() {
        stopPanel?.close()
        stopPanel = nil
    }

    private func showControlButtons() {
        guard let rect = selectionRectInView else { return }
        isRecording = false
        startButton.isHidden = false
        positionButtons(around: rect)
    }

    private func hideControlButtons() {
        startButton.isHidden = true
        stopButton.isHidden = true
        isRecording = false
        dismissStopPanel()
    }

    override func layout() {
        super.layout()
        if !startButton.isHidden, let rect = selectionRectInView {
            positionButtons(around: rect)
        }
    }

    private func updateButtonStates() {
        if isRecording {
            startButton.title = "Recording…"
            startButton.isEnabled = false
            startButton.isHidden = true
            stopButton.isHidden = true
        } else {
            startButton.title = "Start"
            startButton.isEnabled = true
            startButton.isHidden = false
            stopButton.isHidden = true
            stopButton.isEnabled = false
        }
    }

    private func positionButtons(around rect: NSRect) {
        let horizontalSpacing: CGFloat = 12
        let verticalSpacing: CGFloat = 12

        startButton.sizeToFit()
        stopButton.sizeToFit()

        let buttonHeight = max(startButton.frame.height, stopButton.frame.height)
        let buttonWidth = max(max(startButton.frame.width, stopButton.frame.width), 80)

        startButton.frame.size = NSSize(width: buttonWidth, height: buttonHeight)
        stopButton.frame.size = NSSize(width: buttonWidth, height: buttonHeight)

        let visibleButtons = [startButton, stopButton].filter { !$0.isHidden }
        guard !visibleButtons.isEmpty else { return }

        let totalWidth = CGFloat(visibleButtons.count) * buttonWidth + CGFloat(max(0, visibleButtons.count - 1)) * horizontalSpacing

        var originX = rect.midX - totalWidth / 2
        originX = max(20, min(originX, bounds.width - totalWidth - 20))

        var originY = rect.minY - buttonHeight - verticalSpacing
        if originY < 20 {
            originY = rect.minY + verticalSpacing
        }

        for (index, button) in visibleButtons.enumerated() {
            let x = originX + CGFloat(index) * (buttonWidth + horizontalSpacing)
            button.setFrameOrigin(NSPoint(x: x, y: originY))
        }
    }

    @objc private func startTapped() {
        guard !isRecording else { return }
        guard let rect = selectionRectOnScreen else { return }
        isRecording = true
        presentStopPanel(for: rect)
        window?.orderOut(nil)
        onStart?()
    }

    @objc private func stopTapped() {
        handleStop()
    }

    private func handleStop() {
        guard isRecording else { return }
        isRecording = false
        dismissStopPanel()
        onStop?()
    }
}

private final class StopFloatingPanel: NSPanel {
    private let stopHandler: () -> Void
    private let stopButton: NSButton

    init(stopHandler: @escaping () -> Void) {
        self.stopHandler = stopHandler
        let contentRect = NSRect(origin: .zero, size: NSSize(width: 140, height: 56))
        self.stopButton = NSButton(title: "Stop", target: nil, action: nil)
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let container = NSVisualEffectView(frame: contentRect)
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        contentView = container

        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        stopButton.bezelStyle = .rounded
        stopButton.font = .systemFont(ofSize: 16, weight: .semibold)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stopButton)

        NSLayoutConstraint.activate([
            stopButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stopButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])

        container.layoutSubtreeIfNeeded()
        let fittingSize = container.fittingSize
        setContentSize(fittingSize)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(relativeTo rect: CGRect) {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)

        let size = frame.size
        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 16

        var originX = rect.midX - size.width / 2
        originX = max(visibleFrame.minX + horizontalPadding, min(originX, visibleFrame.maxX - size.width - horizontalPadding))

        var originY = rect.maxY + verticalPadding
        if originY + size.height > visibleFrame.maxY - verticalPadding {
            originY = rect.minY - size.height - verticalPadding
        }
        if originY < visibleFrame.minY + verticalPadding {
            originY = visibleFrame.minY + verticalPadding
        }

        setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }

    @objc private func stopPressed() {
        stopHandler()
    }
}
