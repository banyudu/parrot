import AppKit
import Carbon

final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var carbonHandlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onPressed: (() -> Void)?
    private var onReleased: (() -> Void)?

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        onPressed: @escaping () -> Void,
        onReleased: (() -> Void)? = nil
    ) {
        unregister()
        self.onPressed = onPressed
        self.onReleased = onReleased

        if kModifierKeyCodes.contains(UInt16(keyCode)) && modifiers == 0 {
            registerModifierKey(keyCode: UInt16(keyCode))
        } else {
            registerCarbonHotkey(keyCode: keyCode, modifiers: modifiers)
        }
    }

    func registerMediaKey(
        nxKeyType: Int,
        onPressed: @escaping () -> Void,
        onReleased: (() -> Void)? = nil
    ) {
        unregister()
        self.onPressed = onPressed
        self.onReleased = onReleased

        let target = nxKeyType
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.subtype.rawValue == 8 else { return }
            let nxKey = Int((event.data1 & 0x7FFF_0000) >> 16)
            guard nxKey == target else { return }
            let keyState = (event.data1 & 0x0000_FF00) >> 8
            if keyState == 0x0A {
                self?.onPressed?()
            } else if keyState == 0x0B {
                self?.onReleased?()
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { event in
            handler(event)
            return event
        }
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = carbonHandlerRef { RemoveEventHandler(ref); carbonHandlerRef = nil }
        _globalCarbonPressedHandler = nil
        _globalCarbonReleasedHandler = nil

        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        onPressed = nil
        onReleased = nil
    }

    deinit { unregister() }

    // MARK: - Carbon

    private func registerCarbonHotkey(keyCode: UInt32, modifiers: UInt32) {
        _globalCarbonPressedHandler = onPressed
        _globalCarbonReleasedHandler = onReleased

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        InstallEventHandler(
            GetApplicationEventTarget(),
            _carbonHotkeyCallback,
            2, &eventTypes, nil,
            &carbonHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: 0x5052_5254, id: 1) // "PRRT"
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // MARK: - Modifier-only

    private func registerModifierKey(keyCode: UInt16) {
        let targetKeyCode = keyCode
        let targetFlag = modifierFlag(for: keyCode) ?? []

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == targetKeyCode else { return }
            if event.modifierFlags.contains(targetFlag) {
                self?.onPressed?()
            } else {
                self?.onReleased?()
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }
}

private var _globalCarbonPressedHandler: (() -> Void)?
private var _globalCarbonReleasedHandler: (() -> Void)?

private func _carbonHotkeyCallback(
    _: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    switch Int(GetEventKind(event)) {
    case kEventHotKeyPressed:  _globalCarbonPressedHandler?()
    case kEventHotKeyReleased: _globalCarbonReleasedHandler?()
    default: break
    }
    return noErr
}
