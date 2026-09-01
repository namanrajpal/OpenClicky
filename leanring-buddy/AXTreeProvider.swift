//
//  AXTreeProvider.swift
//  leanring-buddy
//
//  Accessibility-tree extraction for the frontmost application (M2). Produces
//  two things from one walk:
//  1. A list of RoutableScreenElement with EXACT AppKit-global coordinates,
//     so the router can point at elements with no vision guessing.
//  2. A compact text summary (a few KB) attached to agent prompts, so the
//     agent reads structured context instead of only pixels.
//
//  NATIVE SHELL: uses AppKit + ApplicationServices. Requires the
//  Accessibility permission the app already holds for the CGEvent tap.
//

import AppKit
import ApplicationServices

struct AXTreeSnapshot {
    let applicationName: String
    let elements: [RoutableScreenElement]
    /// One line per element, for the agent prompt. Capped in size.
    let compactSummary: String
}

@MainActor
final class AXTreeProvider {

    private let maxTreeDepth = 12
    private let maxElementsVisited = 800
    private let maxElementsCollected = 120
    private let maxSummaryLines = 80

    /// Roles worth collecting: things a user would ask to find or that
    /// describe the screen. Containers are walked but not collected.
    private let collectableRoles: Set<String> = [
        kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXRadioButtonRole,
        kAXCheckBoxRole, kAXMenuItemRole, kAXMenuBarItemRole, kAXTextFieldRole,
        kAXTextAreaRole, kAXTabGroupRole, "AXLink", "AXTab",
        kAXStaticTextRole, kAXImageRole, kAXSliderRole, kAXComboBoxRole,
    ]

    /// Walks the frontmost app's accessibility tree. Returns nil when there
    /// is no frontmost app or the walk yields nothing (for example an app
    /// that does not implement accessibility).
    func snapshotFrontmostApplication() -> AXTreeSnapshot? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }

        let applicationName = frontmostApplication.localizedName ?? "the app"
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)

        var collectedElements: [RoutableScreenElement] = []
        var visitedCount = 0
        walkElementTree(
            applicationElement,
            depth: 0,
            visitedCount: &visitedCount,
            collected: &collectedElements
        )

        guard !collectedElements.isEmpty else { return nil }

        var summaryLines: [String] = ["frontmost app: \(applicationName)"]
        for element in collectedElements.prefix(maxSummaryLines) {
            // Names only, deliberately no coordinates: AX coordinates are in
            // global display points, which is NEVER the POINT tag's space
            // (screenshot pixels, possibly a lasso crop). Including them
            // anchored smaller models to wrong numbers — the source of
            // systematic pointing misses on region captures.
            summaryLines.append("\(element.role) \"\(element.title)\"")
        }

        return AXTreeSnapshot(
            applicationName: applicationName,
            elements: collectedElements,
            compactSummary: summaryLines.joined(separator: "\n")
        )
    }

    // MARK: - Tree walk

    private func walkElementTree(
        _ element: AXUIElement,
        depth: Int,
        visitedCount: inout Int,
        collected: inout [RoutableScreenElement]
    ) {
        guard depth <= maxTreeDepth,
              visitedCount < maxElementsVisited,
              collected.count < maxElementsCollected else { return }
        visitedCount += 1

        if let collectableElement = makeRoutableElement(from: element) {
            collected.append(collectableElement)
        }

        guard let childElements = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return
        }
        for childElement in childElements {
            walkElementTree(childElement, depth: depth + 1, visitedCount: &visitedCount, collected: &collected)
        }
    }

    private func makeRoutableElement(from element: AXUIElement) -> RoutableScreenElement? {
        guard let role = copyAttribute(element, kAXRoleAttribute) as? String,
              collectableRoles.contains(role) else { return nil }

        // Title falls back through the usual attribute ladder. Static text
        // uses its value, truncated so paragraph blocks don't flood the summary.
        var title = (copyAttribute(element, kAXTitleAttribute) as? String)
            ?? (copyAttribute(element, kAXDescriptionAttribute) as? String)
            ?? ""
        if title.isEmpty, role == kAXStaticTextRole,
           let textValue = copyAttribute(element, kAXValueAttribute) as? String {
            title = String(textValue.prefix(60))
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count >= 2 else { return nil }

        guard let frame = copyElementFrame(element), frame.width > 1, frame.height > 1 else {
            return nil
        }

        // AX frames are CG-global (top-left origin). Convert the center to
        // AppKit-global (bottom-left origin) so pointing can use it directly.
        let centerCG = CGPoint(x: frame.midX, y: frame.midY)
        guard let containingScreen = Self.screenContainingCGPoint(centerCG) else { return nil }
        let primaryScreenHeight = Self.primaryScreenHeight
        let centerAppKit = CGPoint(x: centerCG.x, y: primaryScreenHeight - centerCG.y)

        return RoutableScreenElement(
            role: role.replacingOccurrences(of: "AX", with: "").lowercased(),
            title: title,
            centerPoint: centerAppKit,
            displayFrame: containingScreen.frame
        )
    }

    // MARK: - AX plumbing

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    private func copyElementFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttribute(element, kAXPositionAttribute),
              let sizeValue = copyAttribute(element, kAXSizeAttribute) else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Height of the primary display (origin display), which anchors the
    /// CG-to-AppKit Y-axis flip for global coordinates.
    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.screens.first?.frame.height
            ?? 0
    }

    /// Finds the NSScreen containing a CG-global point (converts per-screen).
    private static func screenContainingCGPoint(_ cgPoint: CGPoint) -> NSScreen? {
        let appKitPoint = CGPoint(x: cgPoint.x, y: primaryScreenHeight - cgPoint.y)
        return NSScreen.screens.first { $0.frame.contains(appKitPoint) } ?? NSScreen.screens.first
    }
}
