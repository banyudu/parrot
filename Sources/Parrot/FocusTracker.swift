import AppKit

struct FocusTarget {
    let app: NSRunningApplication
    let element: AXUIElement
}

final class FocusTracker {
    private(set) var target: FocusTarget?

    func capture() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            NSLog("[Focus] No frontmost application")
            target = nil
            return
        }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard result == .success else {
            NSLog("[Focus] Cannot get focused element from %@ (error %d)", frontApp.localizedName ?? "?", result.rawValue)
            target = nil
            return
        }
        target = FocusTarget(app: frontApp, element: focusedValue as! AXUIElement)
    }

    func restore() -> Bool {
        guard let target else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.app.processIdentifier {
            target.app.activate()
            usleep(50_000)
        }
        AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    func cursorRect() -> CGRect? {
        guard let target else {
            NSLog("[Focus] cursorRect: no target")
            return nil
        }

        if let rect = caretBounds(target.element) {
            NSLog("[Focus] cursorRect: got caret bounds")
            return rect
        }

        if let rect = elementRect(target.element) {
            NSLog("[Focus] cursorRect: got element rect")
            return rect
        }

        if let rect = focusedWindowRect(target.app) {
            NSLog("[Focus] cursorRect: fell back to window rect")
            return rect
        }

        NSLog("[Focus] cursorRect: all methods failed")
        return nil
    }

    private func caretBounds(_ element: AXUIElement) -> CGRect? {
        var rangeValue: AnyObject?
        let rangeOK = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        )
        guard rangeOK == .success, let range = rangeValue else { return nil }

        var boundsValue: AnyObject?
        let boundsOK = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            range,
            &boundsValue
        )
        guard boundsOK == .success, let bv = boundsValue else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(bv as! AXValue, .cgRect, &rect) else { return nil }
        return axRectToScreen(rect)
    }

    private func elementRect(_ element: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return axRectToScreen(CGRect(origin: pos, size: size))
    }

    private func focusedWindowRect(_ app: NSRunningApplication) -> CGRect? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowValue
        ) == .success else { return nil }

        let window = windowValue as! AXUIElement
        return elementRect(window)
    }

    private func axRectToScreen(_ axRect: CGRect) -> CGRect {
        let screenH = NSScreen.main?.frame.height ?? 0
        return CGRect(
            x: axRect.origin.x,
            y: screenH - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }

    func clear() {
        target = nil
    }
}
