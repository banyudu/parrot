import AppKit

final class StatusBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var delegate: AppDelegate?
    private var statusMenuItem: NSMenuItem!

    init(delegate: AppDelegate) {
        self.delegate = delegate

        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Parrot")
            img?.isTemplate = true
            button.image = img
        }

        rebuildMenu()
    }

    func setStatus(_ text: String) {
        statusMenuItem?.title = text
    }

    func setRecording(_ recording: Bool) {
        updateIcon(recording ? "waveform.circle.fill" : "waveform")
    }

    func setLoading(_ loading: Bool) {
        updateIcon(loading ? "ellipsis.circle" : "waveform")
    }

    private func updateIcon(_ name: String) {
        guard let button = statusItem.button else { return }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Parrot")
        img?.isTemplate = true
        button.image = img
    }

    func rebuildMenu() {
        guard let delegate else { return }
        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Initializing...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        let recItem = NSMenuItem(title: "Toggle Recording", action: #selector(onToggleRecording), keyEquivalent: "")
        recItem.target = self
        menu.addItem(recItem)
        menu.addItem(.separator())

        // Polish toggle
        let polishItem = NSMenuItem(
            title: delegate.currentConfig.polishEnabled ? "Polish: On" : "Polish: Off",
            action: #selector(onTogglePolish),
            keyEquivalent: ""
        )
        polishItem.target = self
        menu.addItem(polishItem)

        // Model submenu
        let modelMenu = NSMenu()
        for family in AppConfig.modelFamilies {
            for variant in family.variants {
                let label = "\(family.name) (\(variant.name))"
                let item = NSMenuItem(title: label, action: #selector(onSelectModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = variant.repoId
                item.state = (delegate.currentConfig.model == variant.repoId) ? .on : .off
                modelMenu.addItem(item)
            }
            if family.name != AppConfig.modelFamilies.last?.name {
                modelMenu.addItem(.separator())
            }
        }
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let hkTitle = "Hotkey: \(delegate.currentConfig.hotkeyDisplayString)"
        let hkItem = NSMenuItem(title: hkTitle, action: nil, keyEquivalent: "")
        hkItem.isEnabled = false
        menu.addItem(hkItem)

        let modeLabel = delegate.currentConfig.hotkeyMode == "hold" ? "Mode: Hold" : "Mode: Toggle"
        let modeItem = NSMenuItem(title: modeLabel, action: #selector(onToggleHotkeyMode), keyEquivalent: "")
        modeItem.target = self
        menu.addItem(modeItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Parrot", action: #selector(onQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func onToggleRecording() { delegate?.toggleRecording() }
    @objc private func onTogglePolish() { delegate?.togglePolish() }
    @objc private func onToggleHotkeyMode() { delegate?.toggleHotkeyMode() }
    @objc private func onSelectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.selectModel(id)
    }
    @objc private func onQuit() { NSApp.terminate(nil) }
}
