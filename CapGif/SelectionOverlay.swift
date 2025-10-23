//
//  SelectionOverlay.swift
//  CapGif
//
//  Created by Deepak Joshi on 23/10/25.
//

import Foundation
import SwiftUI
import AppKit

struct SelectionOverlay: NSViewRepresentable {
    let onDone: (CGRect) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> SelectionView {
        let v = SelectionView()
        v.onDone = onDone
        v.onCancel = onCancel
        return v
    }
    func updateNSView(_ nsView: SelectionView, context: Context) {}
}

final class SelectionView: NSView {
    var onDone: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentRect: CGRect?
    private var tracking = false

    override init(frame frameRect: NSRect) {
        super.init(frame: NSScreen.main?.frame ?? .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
      
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let win = window else { return }
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .transient]
        // cover all displays
        let rect = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        win.setFrame(rect, display: true)
        addEscapeMonitor()
    }

    private var escMonitor: Any?
    private func addEscapeMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.onCancel?(); return nil } // ESC
            return e
        }
    }
    deinit { if let escMonitor { NSEvent.removeMonitor(escMonitor) } }

    override func mouseDown(with event: NSEvent) {
        tracking = true
        startPoint = event.locationInWindowOnScreen
        currentRect = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard tracking, let start = startPoint else { return }
        let p = event.locationInWindowOnScreen
        currentRect = CGRect(x: min(start.x, p.x),
                             y: min(start.y, p.y),
                             width: abs(start.x - p.x),
                             height: abs(start.y - p.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        tracking = false
        guard let r = currentRect, r.width > 3, r.height > 3 else { onCancel?(); return }
        onDone?(r)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.2).setFill()
        dirtyRect.fill()

        if let r = currentRect {
            NSColor.clear.setFill()
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .sourceOut
            NSBezierPath(rect: r).fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            NSColor.systemRed.setStroke()
            let path = NSBezierPath(rect: r)
            path.lineWidth = 2
            path.stroke()
        }
    }
}

private extension NSEvent {
    var locationInWindowOnScreen: CGPoint {
        guard let w = window else { return locationInWindow }
        let frame = w.convertToScreen(NSRect(origin: .zero, size: w.frame.size))
        return CGPoint(x: frame.origin.x + locationInWindow.x,
                       y: frame.origin.y + locationInWindow.y)
    }
}
