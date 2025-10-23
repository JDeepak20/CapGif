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
        guard let window else { return }

        let windowPoint = event.locationInWindow
        currentLocal = convert(windowPoint, from: nil)
        currentScreen = window.convertPoint(toScreen: windowPoint)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
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
            if e.keyCode == 53 {
                self?.hideControlButtons()
                self?.onCancel?()
                return nil
            }
            return e
        }
    }
    deinit { if let escMonitor { NSEvent.removeMonitor(escMonitor) } }

    private func showControlButtons() {
        guard let rect = selectionRectInView else { return }
        updateButtonStates()
        positionButtons(around: rect)
        startButton.isHidden = false
        stopButton.isHidden = false
    }

    private func hideControlButtons() {
        startButton.isHidden = true
        stopButton.isHidden = true
        isRecording = false
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
            stopButton.isEnabled = true
        } else {
            startButton.title = "Start"
            startButton.isEnabled = true
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

        let totalWidth = buttonWidth * 2 + horizontalSpacing

        var originX = rect.midX - totalWidth / 2
        originX = max(20, min(originX, bounds.width - totalWidth - 20))

        var originY = rect.minY - buttonHeight - verticalSpacing
        if originY < 20 {
            originY = rect.minY + verticalSpacing
        }

        startButton.setFrameOrigin(NSPoint(x: originX, y: originY))
        stopButton.setFrameOrigin(NSPoint(x: originX + buttonWidth + horizontalSpacing, y: originY))
    }

    @objc private func startTapped() {
        guard !isRecording else { return }
        isRecording = true
        onStart?()
    }

    @objc private func stopTapped() {
        guard isRecording else { return }
        isRecording = false
        updateButtonStates()
        onStop?()
    }
}
