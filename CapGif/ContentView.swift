//
//  ContentView.swift
//  CapGif
//
//  Created by Deepak Joshi on 23/10/25.
//

import SwiftUI
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit
import CoreImage
import CoreMedia

// MARK: - Recorder (ScreenCaptureKit)
final class Recorder: NSObject, ObservableObject, SCStreamDelegate {
    @Published var selectedRect: CGRect? = nil {     // GLOBAL screen coords (points, origin bottom-left)
        didSet {
            if let rect = selectedRect {
                showSelectionIndicator(for: rect)
            } else {
                hideSelectionIndicator()
            }
        }
    }
    @Published var isRecording = false
    @Published var fps: Double = 10
    @Published var durationSeconds: Double = 0

    private var startTime: Date?
    private var frames: [CGImage] = []

    // ScreenCaptureKit
    private var stream: SCStream?
    private let output = StreamOutput()
    private let queue = DispatchQueue(label: "capgif.capture")
    private let ciContext = CIContext(options: nil)
    private var durationTimer: DispatchSourceTimer?
    private var selectionIndicator: SelectionIndicatorWindow?

    override init() {
        super.init()
        output.onFrame = { [weak self] pixelBuffer in
            self?.appendFrame(from: pixelBuffer)
        }
    }

    func start() {
        guard let rectPoints = selectedRect, rectPoints.width > 4, rectPoints.height > 4 else {
            NSSound.beep(); return
        }

        Task { @MainActor in
            do {
                frames.removeAll(keepingCapacity: true)
                durationSeconds = 0
                startTime = Date()
                isRecording = true
                startDurationTimer()

                // 1) Pick the display under the selection (fallback to first)
                let content = try await SCShareableContent.current
                let displayID = displayIDFor(pointRect: rectPoints)
                let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first!
                guard screenFor(displayID: display.displayID) != nil else {
                    throw NSError(domain: "CapGif", code: 99, userInfo: [NSLocalizedDescriptionKey: "Unable to find NSScreen for display"])
                }

            /*    // 2) Convert GLOBAL points -> DISPLAY-LOCAL pixels (top-left origin)
                let scale = backingScaleFor(displayID: display.displayID)
                let rectPixels = convertToDisplayPixelRect(
                    rectPoints,
                    displayFramePoints: nsScreen.frame,
                    scale: scale
                )*/

                // 3) Configure stream (capture full frames; we crop manually)
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(seconds: 1.0 / max(1, fps), preferredTimescale: 600)
                // where to crop from
                // NOTE: do NOT set config.width/height; we crop manually in appendFrame()

                // 4) Start capture
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                self.stream = stream
            } catch {
                self.isRecording = false
                self.stopDurationTimer()
                NSAlert(error: error).runModal()
            }
        }
    }

    func stop() {
        Task { @MainActor in
            do {
                try await stream?.stopCapture()
                stream = nil
                if let start = startTime { durationSeconds = Date().timeIntervalSince(start) }
            } catch {
                NSAlert(error: error).runModal()
            }
            stopDurationTimer()
            isRecording = false
        }
    }

    private func showSelectionIndicator(for rect: CGRect) {
        DispatchQueue.main.async {
            // Close existing indicator if any
            self.selectionIndicator?.close()
            // Create and show new indicator
            self.selectionIndicator = SelectionIndicatorWindow(rect: rect)
            self.selectionIndicator?.show()
        }
    }

    private func hideSelectionIndicator() {
        DispatchQueue.main.async {
            self.selectionIndicator?.close()
            self.selectionIndicator = nil
        }
    }

    // Manually crop each frame so the GIF is exactly the selected region (no empty space)
    private func appendFrame(from pixelBuffer: CVPixelBuffer) {
        guard let rectPoints = selectedRect else { return }

        // Convert full frame (CVPixelBuffer) -> CGImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let fullCG = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        // Build the crop rect in DISPLAY pixel space
        let displayID = displayIDFor(pointRect: rectPoints)
        let scale = backingScaleFor(displayID: displayID)
        guard let nsScreen = screenFor(displayID: displayID) else { return }
        let cropRect = convertToDisplayPixelRect(rectPoints,
                                                 displayFramePoints: nsScreen.frame,
                                                 scale: scale)

        // Crop the CGImage to the selected area
        if let cropped = fullCG.cropping(to: cropRect) {
            frames.append(cropped)
        } else {
            // Fallback (shouldn't happen): append full frame
            frames.append(fullCG)
        }
    }

    func saveGIF(at url: URL) throws {
        guard !frames.isEmpty else {
            throw NSError(domain: "CapGif", code: 1, userInfo: [NSLocalizedDescriptionKey: "No frames captured"])
        }
        let cfType = UTType.gif.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, cfType, frames.count, nil) else {
            throw NSError(domain: "CapGif", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create GIF destination"])
        }

        let loopDict = [kCGImagePropertyGIFLoopCount: 0] as CFDictionary
        let gifProps = [kCGImagePropertyGIFDictionary: loopDict] as CFDictionary
        CGImageDestinationSetProperties(dest, gifProps)

        let delay = 1.0 / max(1, fps)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary

        for f in frames { CGImageDestinationAddImage(dest, f, frameProps) }

        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "CapGif", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize GIF file"])
        }
    }

    // MARK: - SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.isRecording = false
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Helpers

    // Choose the display that contains the selection’s mid-point
    private func displayIDFor(pointRect: CGRect) -> CGDirectDisplayID {
        let mid = CGPoint(x: pointRect.midX, y: pointRect.midY)
        for screen in NSScreen.screens {
            if screen.frame.contains(mid) {
                if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                    return id
                }
            }
        }
        return CGMainDisplayID()
    }

    private func screenFor(displayID: CGDirectDisplayID) -> NSScreen? {
        return NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID
        }
    }

    private func backingScaleFor(displayID: CGDirectDisplayID) -> CGFloat {
        if let screen = screenFor(displayID: displayID) {
            return screen.backingScaleFactor
        }
        return 2.0
    }

    /// Convert GLOBAL Cocoa rect (points, origin bottom-left) into the SELECTED DISPLAY'S pixel space (origin top-left)
    private func convertToDisplayPixelRect(_ globalRectPoints: CGRect,
                                           displayFramePoints: CGRect,
                                           scale: CGFloat) -> CGRect {
        // 1) Make rect relative to display origin (still in points)
        let local = CGRect(
            x: globalRectPoints.origin.x - displayFramePoints.origin.x,
            y: globalRectPoints.origin.y - displayFramePoints.origin.y,
            width: globalRectPoints.size.width,
            height: globalRectPoints.size.height
        )
        // 2) Flip Y within that display (points)
        let flippedYPoints = displayFramePoints.height - (local.origin.y + local.size.height)
        // 3) Scale to pixels
        let pxX = local.origin.x * scale
        let pxY = flippedYPoints * scale
        let pxW = local.size.width * scale
        let pxH = local.size.height * scale
        return CGRect(x: pxX, y: pxY, width: pxW, height: pxH).integral
    }
}

// MARK: - Duration Timer
private extension Recorder {
    func startDurationTimer() {
        durationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.isRecording, let start = self.startTime else { return }
            self.durationSeconds = Date().timeIntervalSince(start)
        }
        durationTimer = timer
        timer.resume()
    }

    func stopDurationTimer() {
        durationTimer?.cancel()
        durationTimer = nil
    }
}

// MARK: - Selection Indicator Window
final class SelectionIndicatorWindow {
    private var window: NSWindow?
    private let rect: CGRect

    init(rect: CGRect) {
        self.rect = rect
    }

    func show() {
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = SelectionIndicatorView(frame: rect)
        window.contentView = view
        window.orderFront(nil)
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

final class SelectionIndicatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw a red border with slight transparency
        NSColor.systemRed.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        path.lineWidth = 4
        path.stroke()

        // Optional: Add corner indicators for better visibility
        let cornerSize: CGFloat = 20
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        let cornerPath = NSBezierPath()
        cornerPath.lineWidth = 3

        // Top-left corner
        cornerPath.move(to: NSPoint(x: 0, y: cornerSize))
        cornerPath.line(to: NSPoint(x: 0, y: 0))
        cornerPath.line(to: NSPoint(x: cornerSize, y: 0))

        // Top-right corner
        cornerPath.move(to: NSPoint(x: bounds.width - cornerSize, y: 0))
        cornerPath.line(to: NSPoint(x: bounds.width, y: 0))
        cornerPath.line(to: NSPoint(x: bounds.width, y: cornerSize))

        // Bottom-right corner
        cornerPath.move(to: NSPoint(x: bounds.width, y: bounds.height - cornerSize))
        cornerPath.line(to: NSPoint(x: bounds.width, y: bounds.height))
        cornerPath.line(to: NSPoint(x: bounds.width - cornerSize, y: bounds.height))

        // Bottom-left corner
        cornerPath.move(to: NSPoint(x: cornerSize, y: bounds.height))
        cornerPath.line(to: NSPoint(x: 0, y: bounds.height))
        cornerPath.line(to: NSPoint(x: 0, y: bounds.height - cornerSize))

        cornerPath.stroke()
    }
}

// MARK: - StreamOutput
final class StreamOutput: NSObject, SCStreamOutput {
    var onFrame: ((CVPixelBuffer) -> Void)?

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              let pb = sampleBuffer.imageBuffer else { return }
        onFrame?(pb)
    }
}

// MARK: - SwiftUI UI
struct ContentView: View {
    @StateObject private var recorder = Recorder()
    @State private var lastSaveURL: URL?

    var body: some View {
        VStack(spacing: 16) {
            Text("CapGif").font(.system(size: 26, weight: .semibold))
            Text(recorder.selectedRect != nil ? "Selected: \(pretty(recorder.selectedRect!))" : "No region selected")
                .font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Select Region") {
                    RegionSelector.present { rect in
                        recorder.selectedRect = rect
                    } onCancel: {
                        // cancelled
                    }
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button(recorder.isRecording ? "Recording…" : "Start") {
                    recorder.start()
                }
                .disabled(recorder.selectedRect == nil || recorder.isRecording)

                Button("Stop") { recorder.stop() }
                    .disabled(!recorder.isRecording)

                Button("Save GIF") { save() }
                    .disabled(recorder.isRecording)
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("FPS: \(Int(recorder.fps))")
                    Slider(value: $recorder.fps, in: 3...30, step: 1)
                        .frame(width: 220)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Duration: \(String(format: "%.1fs", recorder.durationSeconds))")
                    if let url = lastSaveURL {
                        Text("Saved to: \(url.lastPathComponent)")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                }
            }

            Spacer()
            Text("Tip: Select a region → Start → Stop → Save. Grant Screen Recording in System Settings.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520, height: 300)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "capture.gif"
        panel.begin { resp in
            if resp == .OK, let url = panel.url {
                do {
                    try recorder.saveGIF(at: url)
                    lastSaveURL = url
                    NSSound(named: NSSound.Name("Glass"))?.play()
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    private func pretty(_ r: CGRect) -> String {
        "x:\(Int(r.origin.x)) y:\(Int(r.origin.y)) w:\(Int(r.width)) h:\(Int(r.height))"
    }
}
