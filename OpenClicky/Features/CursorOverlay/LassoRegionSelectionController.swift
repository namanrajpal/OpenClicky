//
//  LassoRegionSelectionController.swift
//  OpenClicky
//
//  Input-side region selection (UX baseline D5, revisited): while the user
//  holds push-to-talk, they can click-drag a freeform lasso on the overlay to
//  select the part of the screen their question is about. On release, the
//  lasso's bounding rectangle is captured (always a rectangular image) and
//  sent to the agent instead of the whole display.
//
//  Mechanics: the overlay panels are normally click-through. While a lasso
//  session is active the panels accept mouse events (so the drag doesn't
//  click whatever is underneath) and a local NSEvent monitor collects the
//  drag path in global AppKit coordinates. Everything is restored on end.
//

import AppKit

@MainActor
final class LassoRegionSelectionController {

    /// Minimum bounding-box size (in points) for a drag to count as a
    /// deliberate region selection rather than a stray click.
    private static let minimumSelectionSideInPoints: CGFloat = 24
    private static let minimumPointCount = 3

    private var localMouseEventMonitor: Any?
    private var draggedPoints: [CGPoint] = []
    private var isDragInProgress = false
    private(set) var isActive = false

    /// Called on every path change so the overlay can render the live stroke.
    /// Points are global AppKit coordinates (bottom-left origin).
    var onLassoPathChanged: (([CGPoint]) -> Void)?

    /// Starts a lasso session: the caller must have already made the overlay
    /// panels mouse-interactive (OverlayWindowManager.setLassoInteractionEnabled).
    func begin() {
        guard !isActive else { return }
        isActive = true
        draggedPoints = []
        isDragInProgress = false

        localMouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] mouseEvent in
            guard let self, self.isActive else { return mouseEvent }

            let globalPoint = NSEvent.mouseLocation
            switch mouseEvent.type {
            case .leftMouseDown:
                self.isDragInProgress = true
                self.draggedPoints = [globalPoint]
                self.onLassoPathChanged?(self.draggedPoints)
            case .leftMouseDragged:
                guard self.isDragInProgress else { break }
                self.draggedPoints.append(globalPoint)
                self.onLassoPathChanged?(self.draggedPoints)
            case .leftMouseUp:
                self.isDragInProgress = false
            default:
                break
            }
            // Consume the event so the drag never leaks into our own UI.
            // (Events over other apps never reach this monitor; the overlay
            // panel's mouse-interactivity is what swallows those.)
            return nil
        }
    }

    /// Ends the session and returns the selection's bounding rectangle in
    /// global AppKit coordinates, or nil when the drag was too small or
    /// absent. Clears the stroke either way.
    func end() -> CGRect? {
        guard isActive else { return nil }
        isActive = false
        isDragInProgress = false

        if let monitor = localMouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseEventMonitor = nil
        }

        defer {
            draggedPoints = []
            onLassoPathChanged?([])
        }

        guard draggedPoints.count >= Self.minimumPointCount else { return nil }

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for point in draggedPoints {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        let boundingRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard boundingRect.width >= Self.minimumSelectionSideInPoints,
              boundingRect.height >= Self.minimumSelectionSideInPoints else {
            return nil
        }
        return boundingRect
    }
}
