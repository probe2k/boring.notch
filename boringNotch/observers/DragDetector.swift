//
//  DragDetector.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-20.
//

import Cocoa
import UniformTypeIdentifiers

final class DragDetector {

    // MARK: - Callbacks

    typealias VoidCallback = () -> Void
    typealias PositionCallback = (_ globalPoint: CGPoint) -> Void

    var onDragEntersNotchRegion: VoidCallback?
    var onDragExitsNotchRegion: VoidCallback?
    var onDragMove: PositionCallback?


    private var mouseDownMonitor: Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor: Any?

    private var pasteboardChangeCount: Int = -1
    private var isDragging: Bool = false
    private var isContentDragging: Bool = false
    private var hasEnteredNotchRegion: Bool = false
    
    // Throttling to reduce CPU usage
    private var lastProcessedTime: TimeInterval = 0
    private let throttleInterval: TimeInterval = 0.06 // ~16 times per second max
    private var cachedHasValidContent: Bool = false

    private let notchRegion: CGRect
    private let dragPasteboard = NSPasteboard(name: .drag)

    init(notchRegion: CGRect) {
        self.notchRegion = notchRegion
    }

    // MARK: - Private Helpers
    
    /// Checks if the drag pasteboard contains valid content types that can be dropped on the shelf
    private func hasValidDragContent() -> Bool {
        let validTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType(UTType.url.identifier),
            .string
        ]
        return dragPasteboard.types?.contains(where: validTypes.contains) ?? false
    }

    func startMonitoring() {
        stopMonitoring()

        // Track pasteboard to detect content drag
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            self.pasteboardChangeCount = self.dragPasteboard.changeCount
            self.isDragging = true
            self.isContentDragging = false
            self.hasEnteredNotchRegion = false
            self.cachedHasValidContent = false
            self.lastProcessedTime = 0
        }

        // Track drag movement and notch region intersection
        mouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            guard let self = self else { return }
            guard self.isDragging else { return }
            
            // Throttle event processing to reduce CPU usage
            let currentTime = Date().timeIntervalSince1970
            let timeSinceLastProcess = currentTime - self.lastProcessedTime
            
            // Only process every throttleInterval seconds (~16 times/sec instead of 60+)
            guard timeSinceLastProcess >= self.throttleInterval else { return }
            self.lastProcessedTime = currentTime

            let newContent = self.dragPasteboard.changeCount != self.pasteboardChangeCount
            
            // Detect if actual content is being dragged AND it's valid content
            // Cache the validation result to avoid repeated pasteboard checks
            if newContent && !self.isContentDragging {
                self.cachedHasValidContent = self.hasValidDragContent()
                if self.cachedHasValidContent {
                    self.isContentDragging = true
                }
            }

            // Only process position when content is being dragged
            if self.isContentDragging {
                let mouseLocation = NSEvent.mouseLocation
                self.onDragMove?(mouseLocation)
                
                // Track notch region entry/exit
                let containsMouse = self.notchRegion.contains(mouseLocation)
                if containsMouse && !self.hasEnteredNotchRegion {
                    self.hasEnteredNotchRegion = true
                    self.onDragEntersNotchRegion?()
                } else if !containsMouse && self.hasEnteredNotchRegion {
                    self.hasEnteredNotchRegion = false
                    self.onDragExitsNotchRegion?()
                }
            }
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self = self else { return }
            guard self.isDragging else { return }
            
            self.isDragging = false
            self.isContentDragging = false
            self.hasEnteredNotchRegion = false
            self.pasteboardChangeCount = -1
            self.cachedHasValidContent = false
            self.lastProcessedTime = 0
        }
    }

    func stopMonitoring() {
        [mouseDownMonitor, mouseDraggedMonitor, mouseUpMonitor].forEach { monitor in
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        mouseDownMonitor = nil
        mouseDraggedMonitor = nil
        mouseUpMonitor = nil
        isDragging = false
        isContentDragging = false
        hasEnteredNotchRegion = false
    }

    deinit {
        stopMonitoring()
    }
}
