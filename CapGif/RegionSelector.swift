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

        let view = SelectionCaptureView(frame: union)
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
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class SelectionCaptureView: NSView {
    var onDone: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var start: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.20).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    private var globalMouse: CGPoint { NSEvent.mouseLocation }

    override func mouseDown(with event: NSEvent) {
        start = globalMouse
        current = start
        print("[DEBUG] mouseDown - start: x=\(start!.x) y=\(start!.y)")
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = globalMouse
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let a = start, let b = current else { onCancel?(); return }
        print("[DEBUG] mouseUp - start: x=\(a.x) y=\(a.y), end: x=\(b.x) y=\(b.y)")
        // Round coordinates to whole pixels for precise alignment
        let minX = round(min(a.x, b.x))
        let minY = round(min(a.y, b.y))
        let maxX = round(max(a.x, b.x))
        let maxY = round(max(a.y, b.y))
        let r = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        print("[DEBUG] RegionSelector final rect: x=\(r.origin.x) y=\(r.origin.y) w=\(r.width) h=\(r.height)")
        if r.width < 3 || r.height < 3 { onCancel?() } else { onDone?(r) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // dim everything
        NSColor.black.withAlphaComponent(0.20).setFill()
        dirtyRect.fill()

        if let a = start, let b = current {
            let r = NSRect(x: min(a.x, b.x),
                           y: min(a.y, b.y),
                           width: abs(a.x - b.x),
                           height: abs(a.y - b.y))

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

    // ESC to cancel - override keyDown for direct handling
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            print("[DEBUG] ESC key pressed in RegionSelector")
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}
