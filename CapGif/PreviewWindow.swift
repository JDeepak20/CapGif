//
//  PreviewWindow.swift
//  CapGif
//
//  Created by Deepak Joshi on 24/10/25.
//

import SwiftUI
import AppKit

/// Preview window that displays the captured GIF with action buttons
class PreviewWindow {
    private var window: NSWindow?
    private let frames: [CGImage]
    private let fps: Double
    
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onRecapture: (() -> Void)?
    
    init(frames: [CGImage], fps: Double) {
        self.frames = frames
        self.fps = fps
    }
    
    func show() {
        let contentView = PreviewContentView(
            frames: frames,
            fps: fps,
            onSave: { [weak self] in
                self?.close()
                self?.onSave?()
            },
            onDiscard: { [weak self] in
                self?.close()
                self?.onDiscard?()
            },
            onRecapture: { [weak self] in
                self?.close()
                self?.onRecapture?()
            }
        )
        
        let hostingController = NSHostingController(rootView: contentView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preview"
        window.contentViewController = hostingController
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - SwiftUI Preview Content
struct PreviewContentView: View {
    let frames: [CGImage]
    let fps: Double
    let onSave: () -> Void
    let onDiscard: () -> Void
    let onRecapture: () -> Void
    
    @State private var currentFrameIndex = 0
    @State private var timer: Timer?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Preview")
                .font(.system(size: 24, weight: .semibold))
                .padding(.top, 20)
            
            // GIF Preview
            if !frames.isEmpty {
                ZStack {
                    Color.black.opacity(0.1)
                    
                    let nsImage = NSImage(cgImage: frames[currentFrameIndex], size: .zero)
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 560, maxHeight: 500)
                }
                .frame(maxWidth: 560, maxHeight: 500)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            } else {
                Text("No frames captured")
                    .foregroundStyle(.secondary)
                    .frame(height: 400)
            }
            
            // Info
            HStack {
                Text("\(frames.count) frames")
                Text("•")
                Text("\(Int(fps)) FPS")
                Text("•")
                Text(String(format: "%.1fs", Double(frames.count) / fps))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            
            // Action Buttons
            HStack(spacing: 16) {
                Button("Discard") {
                    onDiscard()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                
                Button("Recapture") {
                    onRecapture()
                }
                .keyboardShortcut("r", modifiers: [.command])
                
                Button("Save GIF") {
                    onSave()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 600, height: 700)
        .onAppear {
            startAnimation()
        }
        .onDisappear {
            stopAnimation()
        }
    }
    
    private func startAnimation() {
        guard frames.count > 1 else { return }
        
        let interval = 1.0 / fps
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            currentFrameIndex = (currentFrameIndex + 1) % frames.count
        }
    }
    
    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }
}
