import AppKit

struct FocusTarget {
    let app: NSRunningApplication
    let element: AXUIElement
}

final class FocusTracker {
    private(set) var target: FocusTarget?

    func capture() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            target = nil
            return
        }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard result == .success else {
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
        guard let target else { return nil }

        var rangeValue: AnyObject?
        let rangeOK = AXUIElementCopyAttributeValue(
            target.element, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        )
        if rangeOK == .success, let range = rangeValue {
            var boundsValue: AnyObject?
            let boundsOK = AXUIElementCopyParameterizedAttributeValue(
                target.element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                range,
                &boundsValue
            )
            if boundsOK == .success, let bv = boundsValue {
                var rect = CGRect.zero
                if AXValueGetValue(bv as! AXValue, .cgRect, &rect) {
                    return axRectToScreen(rect)
                }
            }
        }

        return elementRect()
    }

    private func elementRect() -> CGRect? {
        guard let target else { return nil }
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(target.element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(target.element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return axRectToScreen(CGRect(origin: pos, size: size))
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
