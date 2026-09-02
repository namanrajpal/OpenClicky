//
//  CompanionScreenCaptureUtility.swift
//  OpenClicky
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        try await captureScreensAsJPEG(activeDisplayOnly: false)
    }

    /// Captures just a user-selected region (global AppKit rect, from the
    /// lasso's bounding box) as a single labeled JPEG. The returned capture
    /// describes the REGION as its display frame, so the existing POINT
    /// coordinate mapping works unchanged on cropped captures.
    static func captureRegionAsJPEG(globalRegionRect: CGRect) async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Find the display containing the region's center and clamp the
        // region to that display's bounds.
        let regionCenter = CGPoint(x: globalRegionRect.midX, y: globalRegionRect.midY)
        guard let display = content.displays.first(where: { display in
            (nsScreenByDisplayID[display.displayID]?.frame ?? display.frame).contains(regionCenter)
        }) ?? content.displays.first else {
            throw NSError(domain: "CompanionScreenCapture", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "No display found for the selected region"])
        }
        let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
            ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                      width: CGFloat(display.width), height: CGFloat(display.height))
        let clampedRegion = globalRegionRect.intersection(displayFrame)
        guard !clampedRegion.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Selected region is off-screen"])
        }

        // Convert the global AppKit rect (bottom-left origin) to the
        // display-local top-left-origin rect that SCStreamConfiguration
        // sourceRect expects, in points.
        let localSourceRect = CGRect(
            x: clampedRegion.minX - displayFrame.minX,
            y: displayFrame.maxY - clampedRegion.maxY,
            width: clampedRegion.width,
            height: clampedRegion.height
        )

        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localSourceRect
        // 2x for Retina sharpness, capped at the usual payload limit.
        let regionAspectRatio = clampedRegion.width / clampedRegion.height
        let targetWidth = min(Int(clampedRegion.width * 2), 1280)
        configuration.width = targetWidth
        configuration.height = Int(CGFloat(targetWidth) / regionAspectRatio)

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        if cgImage.width != configuration.width || cgImage.height != configuration.height {
            print("📸 Region capture: SCK returned \(cgImage.width)x\(cgImage.height) for requested \(configuration.width)x\(configuration.height)")
        }
        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw NSError(domain: "CompanionScreenCapture", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode region capture"])
        }

        return [CompanionScreenCapture(
            imageData: jpegData,
            label: "region of the user's screen they selected by drawing around it (their question is about this area)",
            isCursorScreen: true,
            displayWidthInPoints: Int(clampedRegion.width),
            displayHeightInPoints: Int(clampedRegion.height),
            displayFrame: clampedRegion,
            // ACTUAL image dimensions, not the requested configuration ones.
            // The model sees (and answers in) the real image's pixel space;
            // SCK may adjust output size, and any mismatch is a systematic
            // POINT scale error.
            screenshotWidthInPixels: cgImage.width,
            screenshotHeightInPixels: cgImage.height
        )]
    }

    /// M2 capture discipline: `activeDisplayOnly` captures just the display
    /// the cursor is on. Less of the screen leaves the machine and the agent
    /// payload shrinks by one JPEG per extra monitor.
    static func captureScreensAsJPEG(activeDisplayOnly: Bool) async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        // Active-display-only mode: keep just the cursor screen (it sorted
        // first). Falls back to the first display when the cursor is on none
        // (for example mid-transition between displays).
        let displaysToCapture = activeDisplayOnly
            ? Array(sortedDisplays.prefix(1))
            : sortedDisplays

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in displaysToCapture.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if displaysToCapture.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(displaysToCapture.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(displaysToCapture.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                // ACTUAL image dimensions (see region path note): SCK may
                // adjust output size vs the requested configuration, and the
                // POINT coordinate space is the real image the model sees.
                screenshotWidthInPixels: cgImage.width,
                screenshotHeightInPixels: cgImage.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }
}
