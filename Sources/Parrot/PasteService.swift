import AppKit
import Carbon

enum PasteService {
    static func paste(_ text: String, copyToClipboard: Bool = false) {
        let pb = NSPasteboard.general
        let savedItems = copyToClipboard ? nil : snapshotClipboard(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)
        let expectedChangeCount = pb.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulatePaste()

            if let savedItems {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard pb.changeCount == expectedChangeCount else { return }
                    restoreClipboard(pb, items: savedItems)
                }
            }
        }
    }

    private static func snapshotClipboard(_ pb: NSPasteboard) -> [NSPasteboardItem]? {
        guard let items = pb.pasteboardItems else { return [] }
        var copied: [NSPasteboardItem] = []
        for original in items {
            let item = NSPasteboardItem()
            var hasData = false
            for type in original.types {
                if let data = original.data(forType: type) {
                    item.setData(data, forType: type)
                    hasData = true
                }
            }
            if !hasData { return nil }
            copied.append(item)
        }
        return copied
    }

    private static func restoreClipboard(_ pb: NSPasteboard, items: [NSPasteboardItem]) {
        pb.clearContents()
        if !items.isEmpty {
            pb.writeObjects(items)
        }
    }

    static func ensureAccessibility() {
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    static func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            let chars = [UniChar(scalar.value)]
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: chars)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: chars)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static func deleteBackward(count: Int) {
        guard count > 0 else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: false)
            else { continue }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static func replaceText(from oldText: String, to newText: String) {
        let commonLen = zip(oldText, newText).prefix(while: { $0 == $1 }).count
        let deleteCount = oldText.count - commonLen
        let appendStr = String(newText.dropFirst(commonLen))
        deleteBackward(count: deleteCount)
        typeText(appendStr)
    }

    private static func simulatePaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags   = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
