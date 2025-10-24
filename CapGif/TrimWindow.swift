//
//  TrimWindow.swift
//  CapGif
//
//  Created by Deepak Joshi on 24/10/25.
//

import SwiftUI
import AppKit

/// Trim window that allows selecting start and end frames
class TrimWindow {
    private var window: NSWindow?
    private let frames: [CGImage]
    private let fps: Double
    
    var onSave: (([CGImage]) -> Void)?
    var onCancel: (() -> Void)?
    
    init(frames: [CGImage], fps: Double) {
        self.frames = frames
        self.fps = fps
    }
    
    func show() {
        let contentView = TrimContentView(
            frames: frames,
            fps: fps,
            onSave: { [weak self] trimmedFrames in
                self?.close()
                self?.onSave?(trimmedFrames)
            },
            onCancel: { [weak self] in
                self?.close()
                self?.onCancel?()
            }
        )
        
        let hostingController = NSHostingController(rootView: contentView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 750),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Trim GIF"
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

// MARK: - SwiftUI Trim Content
struct TrimContentView: View {
    let frames: [CGImage]
    let fps: Double
    let onSave: ([CGImage]) -> Void
    let onCancel: () -> Void
    
    @State private var currentFrameIndex = 0
    @State private var startFrame = 0
    @State private var endFrame: Int
    @State private var timer: Timer?
    @State private var isPlaying = true
    
    init(frames: [CGImage], fps: Double, onSave: @escaping ([CGImage]) -> Void, onCancel: @escaping () -> Void) {
        self.frames = frames
        self.fps = fps
        self.onSave = onSave
        self.onCancel = onCancel
        self._endFrame = State(initialValue: frames.count - 1)
        self._currentFrameIndex = State(initialValue: 0)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Trim GIF")
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
                        .frame(maxWidth: 660, maxHeight: 450)
                }
                .frame(maxWidth: 660, maxHeight: 450)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            }
            
            // Playback controls
            HStack(spacing: 16) {
                Button(isPlaying ? "Pause" : "Play") {
                    isPlaying.toggle()
                    if isPlaying {
                        startAnimation()
                    } else {
                        stopAnimation()
                    }
                }
                .frame(width: 80)
                
                Text("Frame \(currentFrameIndex + 1) / \(frames.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Timeline scrubber
            VStack(alignment: .leading, spacing: 8) {
                Text("Current Position")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Slider(value: Binding(
                    get: { Double(currentFrameIndex) },
                    set: { newValue in
                        currentFrameIndex = Int(newValue)
                    }
                ), in: 0...Double(frames.count - 1), step: 1)
                .disabled(isPlaying)
            }
            .padding(.horizontal)
            
            Divider()
            
            // Trim controls
            VStack(alignment: .leading, spacing: 16) {
                Text("Trim Range")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Start: Frame \(startFrame + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("End: Frame \(endFrame + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    RangeSlider(
                        startValue: $startFrame,
                        endValue: $endFrame,
                        range: 0...(frames.count - 1),
                        onValueChanged: {
                            // Keep current frame within trim range
                            if currentFrameIndex < startFrame {
                                currentFrameIndex = startFrame
                            } else if currentFrameIndex > endFrame {
                                currentFrameIndex = endFrame
                            }
                        }
                    )
                    .frame(height: 30)
                }
                
                // Info about trimmed result
                HStack {
                    Text("Trimmed: \(endFrame - startFrame + 1) frames")
                    Text("•")
                    Text(String(format: "%.1fs", Double(endFrame - startFrame + 1) / fps))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Action Buttons
            HStack(spacing: 16) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Button("Save Trimmed GIF") {
                    let trimmedFrames = Array(frames[startFrame...endFrame])
                    onSave(trimmedFrames)
                }
                .keyboardShortcut("s", modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .disabled(startFrame > endFrame)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 700, height: 750)
        .onAppear {
            if isPlaying {
                startAnimation()
            }
        }
        .onDisappear {
            stopAnimation()
        }
    }
    
    private func startAnimation() {
        guard frames.count > 1 else { return }
        
        let interval = 1.0 / fps
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            // Loop within the trim range
            if currentFrameIndex >= endFrame {
                currentFrameIndex = startFrame
            } else {
                currentFrameIndex += 1
            }
        }
    }
    
    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Range Slider
struct RangeSlider: NSViewRepresentable {
    @Binding var startValue: Int
    @Binding var endValue: Int
    let range: ClosedRange<Int>
    let onValueChanged: () -> Void
    
    func makeNSView(context: Context) -> RangeSliderView {
        let view = RangeSliderView(
            startValue: startValue,
            endValue: endValue,
            range: range
        )
        view.onValueChanged = { start, end in
            startValue = start
            endValue = end
            onValueChanged()
        }
        return view
    }
    
    func updateNSView(_ nsView: RangeSliderView, context: Context) {
        nsView.updateValues(start: startValue, end: endValue)
    }
}

class RangeSliderView: NSView {
    var onValueChanged: ((Int, Int) -> Void)?
    
    private var startValue: Int
    private var endValue: Int
    private let range: ClosedRange<Int>
    
    private var isDraggingStart = false
    private var isDraggingEnd = false
    
    private let thumbWidth: CGFloat = 12
    private let trackHeight: CGFloat = 6
    
    init(startValue: Int, endValue: Int, range: ClosedRange<Int>) {
        self.startValue = startValue
        self.endValue = endValue
        self.range = range
        super.init(frame: .zero)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateValues(start: Int, end: Int) {
        if startValue != start || endValue != end {
            startValue = start
            endValue = end
            needsDisplay = true
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let trackY = (bounds.height - trackHeight) / 2
        let trackRect = NSRect(x: thumbWidth / 2, y: trackY, width: bounds.width - thumbWidth, height: trackHeight)
        
        // Draw background track
        NSColor.quaternaryLabelColor.setFill()
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
        trackPath.fill()
        
        // Draw selected range
        let startX = xPosition(for: startValue)
        let endX = xPosition(for: endValue)
        let rangeRect = NSRect(x: startX, y: trackY, width: endX - startX, height: trackHeight)
        NSColor.controlAccentColor.setFill()
        let rangePath = NSBezierPath(roundedRect: rangeRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
        rangePath.fill()
        
        // Draw start thumb
        drawThumb(at: startX, y: bounds.height / 2)
        
        // Draw end thumb
        drawThumb(at: endX, y: bounds.height / 2)
    }
    
    private func drawThumb(at x: CGFloat, y: CGFloat) {
        let thumbRect = NSRect(x: x - thumbWidth / 2, y: y - thumbWidth / 2, width: thumbWidth, height: thumbWidth)
        NSColor.white.setFill()
        let thumbPath = NSBezierPath(ovalIn: thumbRect)
        thumbPath.fill()
        
        NSColor.controlAccentColor.setStroke()
        thumbPath.lineWidth = 2
        thumbPath.stroke()
    }
    
    private func xPosition(for value: Int) -> CGFloat {
        let trackWidth = bounds.width - thumbWidth
        let normalizedValue = CGFloat(value - range.lowerBound) / CGFloat(range.upperBound - range.lowerBound)
        return thumbWidth / 2 + normalizedValue * trackWidth
    }
    
    private func valueForPosition(_ x: CGFloat) -> Int {
        let trackWidth = bounds.width - thumbWidth
        let normalizedX = max(0, min(1, (x - thumbWidth / 2) / trackWidth))
        let value = range.lowerBound + Int(round(normalizedX * CGFloat(range.upperBound - range.lowerBound)))
        return max(range.lowerBound, min(range.upperBound, value))
    }
    
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let startX = xPosition(for: startValue)
        let endX = xPosition(for: endValue)
        
        let distToStart = abs(location.x - startX)
        let distToEnd = abs(location.x - endX)
        
        if distToStart < distToEnd && distToStart < 20 {
            isDraggingStart = true
        } else if distToEnd < 20 {
            isDraggingEnd = true
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let newValue = valueForPosition(location.x)
        
        if isDraggingStart {
            startValue = min(newValue, endValue)
            onValueChanged?(startValue, endValue)
            needsDisplay = true
        } else if isDraggingEnd {
            endValue = max(newValue, startValue)
            onValueChanged?(startValue, endValue)
            needsDisplay = true
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        isDraggingStart = false
        isDraggingEnd = false
    }
}
