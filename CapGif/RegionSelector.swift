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
    static func present(onDone: @escaping (CGRect) -> Void,
                        onCancel: @escaping () -> Void) {
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
            window.orderOut(nil)
            onDone(rect)
        }
        view.onCancel = {
            window.orderOut(nil)
            onCancel()
        }

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class SelectionCaptureView: NSView {
    var onDone: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startLocal: CGPoint?
    private var currentLocal: CGPoint?
    private var startScreen: CGPoint?
    private var currentScreen: CGPoint?

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
            onCancel?()
            return
        }

        if rectOnScreen.width < 3 || rectOnScreen.height < 3 {
            onCancel?()
        } else {
            onDone?(rectOnScreen)
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
            if e.keyCode == 53 { self?.onCancel?(); return nil }
            return e
        }
    }
    deinit { if let escMonitor { NSEvent.removeMonitor(escMonitor) } }
}
