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
    
    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onShowPreview: (([CGImage], Double) -> Void)?

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

                // 3) Get windows to exclude (indicator overlay windows)
                let excludeWindowIDs = selectionIndicator?.windowNumbers ?? []
                let excludeWindows = content.windows.filter { excludeWindowIDs.contains($0.windowID) }
                
                // 4) Configure stream to capture at display's native resolution
                let filter = SCContentFilter(display: display, excludingWindows: excludeWindows)
                let config = SCStreamConfiguration()
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(seconds: 1.0 / max(1, fps), preferredTimescale: 600)
                
                // Set capture size to match display dimensions to avoid scaling/aspect ratio issues
                // Use display.width/height which are in pixels
                config.width = display.width
                config.height = display.height
                print("[DEBUG] Configuring capture: \(display.width) x \(display.height) pixels")
                print("[DEBUG] Excluding \(excludeWindows.count) windows from capture")

                // 5) Start capture
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                self.stream = stream
                self.selectionIndicator?.updateRecordingState(isRecording: true)
                onStartRecording?()
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
            print("[DEBUG] Recording stopped. Captured \(frames.count) frames")
            // Hide indicator and clear selection after stopping
            hideSelectionIndicator()
            selectedRect = nil
            
            // Show preview window with captured frames
            if !frames.isEmpty {
                onShowPreview?(frames, fps)
            } else {
                onStopRecording?()
            }
        }
    }

    private func showSelectionIndicator(for rect: CGRect) {
        DispatchQueue.main.async {
            // Close existing indicator if any
            self.selectionIndicator?.close()
            // Create and show new indicator
            print("[DEBUG] Selection indicator rect: x=\(rect.origin.x) y=\(rect.origin.y) w=\(rect.width) h=\(rect.height)")
            let indicator = SelectionIndicatorWindow(rect: rect)
            indicator.onStart = { [weak self] in
                self?.start()
            }
            indicator.onStop = { [weak self] in
                self?.stop()
            }
            indicator.onCancel = { [weak self] in
                // Cancel selection - clear rect and hide indicator
                self?.selectedRect = nil
            }
            indicator.onRedraw = { [weak self] in
                // Close current indicator and trigger region selection again
                self?.selectionIndicator?.close()
                self?.selectionIndicator = nil
                RegionSelector.present { rect in
                    self?.selectedRect = rect
                } onCancel: {
                    // If cancelled, restore previous selection or clear
                    // (previous selection already stored in self.selectedRect)
                }
            }
            indicator.show()
            self.selectionIndicator = indicator
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

        // Get display info
        let displayID = displayIDFor(pointRect: rectPoints)
        guard let nsScreen = screenFor(displayID: displayID) else { return }
        
        // Calculate ACTUAL scale from captured frame vs display size
        // ScreenCaptureKit may not capture at full backing scale
        let actualScaleX = CGFloat(fullCG.width) / nsScreen.frame.width
        let actualScaleY = CGFloat(fullCG.height) / nsScreen.frame.height
        
        // Build the crop rect using the actual capture scale
        let cropRect = convertToDisplayPixelRect(rectPoints,
                                                 displayFramePoints: nsScreen.frame,
                                                 scaleX: actualScaleX,
                                                 scaleY: actualScaleY)
        
        // Debug: Log crop rect on first frame only
        if frames.isEmpty {
            print("[DEBUG] === Crop Calculation ===")
            print("[DEBUG] Selection (points): x=\(rectPoints.origin.x) y=\(rectPoints.origin.y) w=\(rectPoints.width) h=\(rectPoints.height)")
            print("[DEBUG] Display frame (points): x=\(nsScreen.frame.origin.x) y=\(nsScreen.frame.origin.y) w=\(nsScreen.frame.width) h=\(nsScreen.frame.height)")
            print("[DEBUG] Full frame size (pixels): \(fullCG.width) x \(fullCG.height)")
            print("[DEBUG] Actual scale: X=\(actualScaleX) Y=\(actualScaleY)")
            print("[DEBUG] Crop rect (pixels): x=\(cropRect.origin.x) y=\(cropRect.origin.y) w=\(cropRect.width) h=\(cropRect.height)")
            print("[DEBUG] Crop rect as % of frame: x=\(cropRect.origin.x / CGFloat(fullCG.width) * 100)% w=\(cropRect.width / CGFloat(fullCG.width) * 100)%")
        }

        // Crop the CGImage to the selected area
        if let cropped = fullCG.cropping(to: cropRect) {
            frames.append(cropped)
        } else {
            // Fallback (shouldn't happen): append full frame
            frames.append(fullCG)
        }
    }

    func getFrames() -> [CGImage] {
        return frames
    }
    
    func clearFrames() {
        frames.removeAll()
        durationSeconds = 0
    }
    
    func updateFrames(_ newFrames: [CGImage]) {
        frames = newFrames
        durationSeconds = Double(newFrames.count) / fps
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
            self.hideSelectionIndicator()
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
                                           scaleX: CGFloat,
                                           scaleY: CGFloat) -> CGRect {
        // 1) Make rect relative to display origin (still in points)
        let local = CGRect(
            x: globalRectPoints.origin.x - displayFramePoints.origin.x,
            y: globalRectPoints.origin.y - displayFramePoints.origin.y,
            width: globalRectPoints.size.width,
            height: globalRectPoints.size.height
        )
        
        // 2) Flip Y within that display (points)
        let flippedYPoints = displayFramePoints.height - (local.origin.y + local.size.height)
        
        // 3) Scale to pixels using actual capture scale - round to avoid sub-pixel shifts
        let pxX = round(local.origin.x * scaleX)
        let pxY = round(flippedYPoints * scaleY)
        let pxW = round(local.size.width * scaleX)
        let pxH = round(local.size.height * scaleY)
        return CGRect(x: pxX, y: pxY, width: pxW, height: pxH)
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
            
            // Update counter in the selection indicator overlay
            let seconds = Int(self.durationSeconds)
            let frameCount = self.frames.count
            self.selectionIndicator?.updateCounter(seconds: seconds, frames: frameCount)
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
    private var indicatorWindow: NSWindow?
    private var dimWindow: NSWindow?
    private var controlWindow: NSWindow?
    private let rect: CGRect
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRedraw: (() -> Void)?
    private var escMonitor: Any?
    
    var windowNumbers: [CGWindowID] {
        var ids: [CGWindowID] = []
        if let dimWin = dimWindow, dimWin.windowNumber > 0 {
            ids.append(CGWindowID(dimWin.windowNumber))
        }
        if let indWin = indicatorWindow, indWin.windowNumber > 0 {
            ids.append(CGWindowID(indWin.windowNumber))
        }
        if let ctrlWin = controlWindow, ctrlWin.windowNumber > 0 {
            ids.append(CGWindowID(ctrlWin.windowNumber))
        }
        return ids
    }

    init(rect: CGRect) {
        self.rect = rect
    }

    func show() {
        // Create full-screen dimming overlay
        let allScreens = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let dimWindow = NSWindow(
            contentRect: allScreens,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        dimWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        dimWindow.backgroundColor = .clear
        dimWindow.isOpaque = false
        dimWindow.hasShadow = false
        dimWindow.ignoresMouseEvents = true
        dimWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        
        let dimView = DimmingView(frame: allScreens, cutoutRect: rect)
        dimWindow.contentView = dimView
        dimWindow.orderFront(nil)
        self.dimWindow = dimWindow
        
        // Create indicator border window on top of dimming
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        // View frame should be relative to window (origin at 0,0), not global coordinates
        let viewFrame = NSRect(origin: .zero, size: rect.size)
        let view = SelectionIndicatorView(frame: viewFrame)
        window.contentView = view
        window.orderFront(nil)
        self.indicatorWindow = window
        
        // Create control buttons window below the selection
        createControlWindow()
    }
    
    private func createControlWindow() {
        let buttonSize: CGFloat = 70
        let spacing: CGFloat = 30
        let padding: CGFloat = 24
        let labelHeight: CGFloat = 16
        let labelTopMargin: CGFloat = 8
        let counterHeight: CGFloat = 20
        let counterTopMargin: CGFloat = 12
        let totalWidth = buttonSize * 4 + spacing * 3 + padding * 2
        let totalHeight = buttonSize + labelHeight + labelTopMargin + counterHeight + counterTopMargin + padding * 2
        
        // Position below the selection rect
        var controlOrigin = CGPoint(x: rect.midX - totalWidth / 2, y: rect.minY - totalHeight - 8)
        // If too close to bottom of screen, position above instead
        if controlOrigin.y < 50 {
            controlOrigin.y = rect.maxY + 8
        }
        
        let controlRect = NSRect(x: controlOrigin.x, y: controlOrigin.y, width: totalWidth, height: totalHeight)
        let ctrlWindow = NSWindow(
            contentRect: controlRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        ctrlWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 2)
        ctrlWindow.backgroundColor = .clear
        ctrlWindow.isOpaque = false
        ctrlWindow.hasShadow = false
        ctrlWindow.ignoresMouseEvents = false
        ctrlWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        
        let controlView = ControlButtonsView(frame: NSRect(origin: .zero, size: controlRect.size))
        controlView.onStart = { [weak self] in self?.onStart?() }
        controlView.onStop = { [weak self] in self?.onStop?() }
        controlView.onCancel = { [weak self] in self?.onCancel?() }
        controlView.onRedraw = { [weak self] in self?.onRedraw?() }
        ctrlWindow.contentView = controlView
        ctrlWindow.orderFront(nil)
        self.controlWindow = ctrlWindow
        
        // Add ESC key monitor to cancel selection
        addEscapeMonitor()
    }
    
    private func addEscapeMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC key
                self?.onCancel?()
                return nil
            }
            return event
        }
    }
    
    func updateRecordingState(isRecording: Bool) {
        if let controlView = controlWindow?.contentView as? ControlButtonsView {
            controlView.updateRecordingState(isRecording: isRecording)
        }
    }
    
    func updateCounter(seconds: Int, frames: Int) {
        if let controlView = controlWindow?.contentView as? ControlButtonsView {
            controlView.updateCounter(seconds: seconds, frames: frames)
        }
    }

    func close() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        dimWindow?.orderOut(nil)
        dimWindow = nil
        indicatorWindow?.orderOut(nil)
        indicatorWindow = nil
        controlWindow?.orderOut(nil)
        controlWindow = nil
    }
}

// MARK: - Control Buttons View
final class ControlButtonsView: NSView {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRedraw: (() -> Void)?
    
    private lazy var counterLabel: NSTextField = {
        let label = NSTextField(labelWithString: "0s | 0 frames")
        label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.8)
        label.alignment = .center
        return label
    }()
    
    private lazy var startButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(startTapped))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.masksToBounds = false
        button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Start")
        button.imagePosition = .imageOnly
        return button
    }()
    
    private lazy var startLabel: NSTextField = {
        let label = NSTextField(labelWithString: "START")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.8)
        label.alignment = .center
        return label
    }()
    
    private lazy var stopButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(stopTapped))
        button.isBordered = false
        button.isEnabled = false
        button.wantsLayer = true
        button.layer?.masksToBounds = false
        button.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
        button.imagePosition = .imageOnly
        return button
    }()
    
    private lazy var stopLabel: NSTextField = {
        let label = NSTextField(labelWithString: "STOP")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.8)
        label.alignment = .center
        return label
    }()
    
    private lazy var cancelButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(cancelTapped))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.masksToBounds = false
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")
        button.imagePosition = .imageOnly
        return button
    }()
    
    private lazy var cancelLabel: NSTextField = {
        let label = NSTextField(labelWithString: "CANCEL")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.8)
        label.alignment = .center
        return label
    }()
    
    private lazy var redrawButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(redrawTapped))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.masksToBounds = false
        button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Redraw")
        button.imagePosition = .imageOnly
        return button
    }()
    
    private lazy var redrawLabel: NSTextField = {
        let label = NSTextField(labelWithString: "REDRAW")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.8)
        label.alignment = .center
        return label
    }()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Pill shape - will be set properly in layout based on actual height
        layer?.backgroundColor = NSColor(white: 0.2, alpha: 1.0).cgColor // Dark grey, no opacity
        
        // Add subtle shadow for depth
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowOffset = CGSize(width: 0, height: 4)
        layer?.shadowRadius = 12
        layer?.masksToBounds = false
        
        addSubview(startButton)
        addSubview(startLabel)
        addSubview(stopButton)
        addSubview(stopLabel)
        addSubview(cancelButton)
        addSubview(cancelLabel)
        addSubview(redrawButton)
        addSubview(redrawLabel)
        addSubview(counterLabel)
    }
    required init?(coder: NSCoder) { fatalError() }
    
    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 70 // Circular button diameter
        let spacing: CGFloat = 30
        let padding: CGFloat = 24
        let labelHeight: CGFloat = 16
        let labelTopMargin: CGFloat = 8
        let counterHeight: CGFloat = 20
        
        // Set rounded rectangle corner radius
        layer?.cornerRadius = 24
        
        // Calculate vertical centering
        // Total content height = buttons + gap + labels
        let contentHeight = buttonSize + labelTopMargin + labelHeight
        let counterBottomSpace = padding + counterHeight + 12 // Space for counter at bottom
        let availableHeight = bounds.height - counterBottomSpace - padding
        
        // Center the buttons + labels vertically in available space
        let buttonsY = counterBottomSpace + (availableHeight - contentHeight) / 2 + labelHeight + labelTopMargin
        
        // Position circular buttons horizontally centered
        let totalButtonsWidth: CGFloat = buttonSize * 4 + spacing * 3
        let startX = (bounds.width - totalButtonsWidth) / 2
        
        startButton.frame = NSRect(x: startX, y: buttonsY, width: buttonSize, height: buttonSize)
        stopButton.frame = NSRect(x: startX + buttonSize + spacing, y: buttonsY, width: buttonSize, height: buttonSize)
        redrawButton.frame = NSRect(x: startX + (buttonSize + spacing) * 2, y: buttonsY, width: buttonSize, height: buttonSize)
        cancelButton.frame = NSRect(x: startX + (buttonSize + spacing) * 3, y: buttonsY, width: buttonSize, height: buttonSize)
        
        // Position labels BELOW buttons (lower Y coordinate)
        let labelsY = buttonsY - labelTopMargin - labelHeight
        startLabel.frame = NSRect(x: startX, y: labelsY, width: buttonSize, height: labelHeight)
        stopLabel.frame = NSRect(x: startX + buttonSize + spacing, y: labelsY, width: buttonSize, height: labelHeight)
        redrawLabel.frame = NSRect(x: startX + (buttonSize + spacing) * 2, y: labelsY, width: buttonSize, height: labelHeight)
        cancelLabel.frame = NSRect(x: startX + (buttonSize + spacing) * 3, y: labelsY, width: buttonSize, height: labelHeight)
        
        // Style buttons as circles - Start is blue initially, others are grey
        let buttonGrey = NSColor(white: 0.4, alpha: 1.0)
        styleCircularButton(startButton, color: .systemBlue) // Start is primary action
        styleCircularButton(stopButton, color: buttonGrey)
        styleCircularButton(redrawButton, color: buttonGrey)
        styleCircularButton(cancelButton, color: buttonGrey)
        
        // Position counter label at bottom center
        let counterWidth: CGFloat = 200
        counterLabel.frame = NSRect(x: (bounds.width - counterWidth) / 2, y: padding, width: counterWidth, height: counterHeight)
    }
    
    func updateRecordingState(isRecording: Bool) {
        startButton.isEnabled = !isRecording
        stopButton.isEnabled = isRecording
        cancelButton.isEnabled = !isRecording
        redrawButton.isEnabled = !isRecording
        
        // Update button colors - active button changes color
        let buttonGrey = NSColor(white: 0.4, alpha: 1.0)
        let buttonBlue = NSColor.systemBlue
        let buttonRed = NSColor.systemRed
        
        if isRecording {
            // During recording: Stop button is red (active/danger), others are grey
            styleCircularButton(startButton, color: buttonGrey)
            styleCircularButton(stopButton, color: buttonRed)
            styleCircularButton(cancelButton, color: buttonGrey)
            styleCircularButton(redrawButton, color: buttonGrey)
        } else {
            // Not recording: Start button is blue (primary action)
            styleCircularButton(startButton, color: buttonBlue)
            styleCircularButton(stopButton, color: buttonGrey)
            styleCircularButton(cancelButton, color: buttonGrey)
            styleCircularButton(redrawButton, color: buttonGrey)
            counterLabel.stringValue = "0s | 0 frames"
        }
    }
    
    func updateCounter(seconds: Int, frames: Int) {
        counterLabel.stringValue = "\(seconds)s | \(frames) frames"
    }
    
    @objc private func startTapped() {
        onStart?()
    }
    
    @objc private func stopTapped() {
        onStop?()
    }
    
    @objc private func cancelTapped() {
        onCancel?()
    }
    
    @objc private func redrawTapped() {
        onRedraw?()
    }
    
    private func styleCircularButton(_ button: NSButton, color: NSColor) {
        // Make button perfectly circular
        let cornerRadius = button.frame.height / 2
        button.layer?.cornerRadius = cornerRadius
        button.layer?.backgroundColor = color.cgColor
        
        // Add shadow for depth
        button.layer?.shadowColor = NSColor.black.cgColor
        button.layer?.shadowOpacity = 0.3
        button.layer?.shadowOffset = CGSize(width: 0, height: 3)
        button.layer?.shadowRadius = 6
        button.layer?.masksToBounds = false
        
        // Ensure icon is white and properly sized
        button.contentTintColor = .white
        if let originalImage = button.image {
            let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
            let styledImage = originalImage.withSymbolConfiguration(config)
            button.image = styledImage
        }
        
        // Force redraw to ensure icon is visible
        button.needsDisplay = true
    }
}

final class DimmingView: NSView {
    private let cutoutRect: CGRect
    
    init(frame frameRect: NSRect, cutoutRect: CGRect) {
        self.cutoutRect = cutoutRect
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // Fill entire screen with 50% black
        NSColor.black.withAlphaComponent(0.5).setFill()
        bounds.fill()
        
        // Cut out the selected region (make it transparent)
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        cutoutRect.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
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

        let cornerRadius: CGFloat = 8
        let borderWidth: CGFloat = 4
        let insetRect = bounds.insetBy(dx: 2, dy: 2)
        
        // Draw blue border with glow effect
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.systemBlue.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = .zero
        shadow.set()
        
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(roundedRect: insetRect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.lineWidth = borderWidth
        path.stroke()
        
        NSGraphicsContext.current?.restoreGraphicsState()

        // Add modern corner handles for better visibility
        let cornerSize: CGFloat = 20
        let cornerThickness: CGFloat = 3
        NSColor.systemBlue.setStroke()
        let cornerPath = NSBezierPath()
        cornerPath.lineWidth = cornerThickness
        cornerPath.lineCapStyle = .round

        // Top-left corner
        cornerPath.move(to: NSPoint(x: cornerSize, y: 0))
        cornerPath.line(to: NSPoint(x: 0, y: 0))
        cornerPath.line(to: NSPoint(x: 0, y: cornerSize))

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
    @State private var appWindow: NSWindow?
    @State private var previewWindow: PreviewWindow?
    @State private var trimWindow: TrimWindow?
    @State private var isShowingPreview = false
    @State private var hasScreenRecordingPermission = false

    var body: some View {
        VStack(spacing: 16) {
            Text("CapGif").font(.system(size: 26, weight: .semibold))
            Text(recorder.selectedRect != nil ? "Selected: \(pretty(recorder.selectedRect!))" : "No region selected")
                .font(.callout).foregroundStyle(.secondary)

            Button(action: {
                RegionSelector.present { rect in
                    recorder.selectedRect = rect
                    // Hide main window immediately after selection
                    appWindow?.orderOut(nil)
                } onCancel: {
                    // cancelled
                }
            }) {
                Label("Select Region", systemImage: "viewfinder.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .keyboardShortcut("s", modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            VStack {
                Text("FPS: \(Int(recorder.fps))")
                    .font(.callout)
                Slider(value: $recorder.fps, in: 3...30, step: 1)
                    .frame(width: 240)
            }

            Spacer()
            VStack(spacing: 4) {
                Text("How to use:")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("1. Click 'Select Region' and drag to choose area")
                    .font(.caption).foregroundStyle(.secondary)
                Text("2. Use Start/Stop buttons on the overlay to record")
                    .font(.caption).foregroundStyle(.secondary)
                Text("3. Preview, trim, and save your GIF")
                    .font(.caption).foregroundStyle(.secondary)
                
                if !hasScreenRecordingPermission {
                    Text("⚠️ Grant Screen Recording permission in System Settings if prompted")
                        .font(.caption2).foregroundStyle(.orange)
                        .padding(.top, 4)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 300)
        .background(WindowAccessor(window: $appWindow))
        .onChange(of: recorder.selectedRect) { oldValue, newValue in
            // Show main window when selection is cleared (but not if preview is showing)
            if newValue == nil && !isShowingPreview {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    appWindow?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .onAppear {
            // Check screen recording permission
            checkScreenRecordingPermission()
            
            // Setup preview window callback
            recorder.onShowPreview = { frames, fps in
                showPreview(frames: frames, fps: fps)
            }
            
            recorder.onStopRecording = { [weak appWindow] in
                // Show main window when recording stops (only if no preview)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    appWindow?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    private func showPreview(frames: [CGImage], fps: Double) {
        // Set flag to prevent main window from appearing
        isShowingPreview = true
        
        // Hide main window before showing preview
        appWindow?.orderOut(nil)
        
        let preview = PreviewWindow(frames: frames, fps: fps)
        
        preview.onSave = {
            saveFromPreview()
        }
        
        preview.onDiscard = {
            recorder.clearFrames()
            isShowingPreview = false
            showMainWindow()
        }
        
        preview.onRecapture = {
            recorder.clearFrames()
            isShowingPreview = false
            showMainWindow()
            // Trigger region selection again
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                RegionSelector.present { rect in
                    recorder.selectedRect = rect
                    appWindow?.orderOut(nil)
                } onCancel: {
                    // cancelled
                }
            }
        }
        
        preview.onTrim = {
            showTrimWindow(frames: frames, fps: fps)
        }
        
        previewWindow = preview
        preview.show()
    }
    
    private func saveFromPreview() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "capture.gif"
        panel.begin { resp in
            if resp == .OK, let url = panel.url {
                do {
                    try recorder.saveGIF(at: url)
                    lastSaveURL = url
                    NSSound(named: NSSound.Name("Glass"))?.play()
                    recorder.clearFrames()
                    isShowingPreview = false
                    showMainWindow()
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }
    
    private func showTrimWindow(frames: [CGImage], fps: Double) {
        let trim = TrimWindow(frames: frames, fps: fps)
        
        trim.onSave = { trimmedFrames in
            // Update recorder with trimmed frames
            recorder.updateFrames(trimmedFrames)
            // Show preview again with trimmed frames
            showPreview(frames: trimmedFrames, fps: fps)
        }
        
        trim.onCancel = {
            // Go back to preview with original frames
            showPreview(frames: frames, fps: fps)
        }
        
        trimWindow = trim
        trim.show()
    }
    
    private func checkScreenRecordingPermission() {
        Task {
            do {
                // Try to get shareable content - this will succeed if permission is granted
                _ = try await SCShareableContent.current
                await MainActor.run {
                    hasScreenRecordingPermission = true
                }
            } catch {
                // Permission not granted or error occurred
                await MainActor.run {
                    hasScreenRecordingPermission = false
                }
            }
        }
    }
    
    private func showMainWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            appWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
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

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            self.window = nsView.window
        }
    }
}
