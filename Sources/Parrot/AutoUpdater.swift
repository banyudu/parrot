import AppKit

final class AutoUpdater {
    static let shared = AutoUpdater()

    private let repo = "banyudu/parrot"
    private var hasCheckedOnLaunch = false

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func checkOnLaunch() {
        guard !hasCheckedOnLaunch else { return }
        hasCheckedOnLaunch = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForUpdates(silent: true)
        }
    }

    func checkForUpdates(silent: Bool = false) {
        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard let data, error == nil, statusCode == 200 else {
                if !silent {
                    DispatchQueue.main.async {
                        if statusCode == 404 {
                            self.showUpToDateAlert()
                        } else {
                            self.showError()
                        }
                    }
                }
                return
            }
            self.handleResponse(data, silent: silent)
        }.resume()
    }

    private func handleResponse(_ data: Data, silent: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let htmlURL = json["html_url"] as? String else {
            if !silent {
                DispatchQueue.main.async { self.showError() }
            }
            return
        }

        let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        DispatchQueue.main.async {
            if self.isNewer(latestVersion, than: self.currentVersion) {
                self.showUpdateAlert(version: latestVersion, url: htmlURL)
            } else if !silent {
                self.showUpToDateAlert()
            }
        }
    }

    private func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    private func showUpdateAlert(version: String, url: String) {
        let alert = NSAlert()
        alert.messageText = "Parrot \(version) Available"
        alert.informativeText = "A new version of Parrot is available. You are currently running \(currentVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            if let downloadURL = URL(string: url) {
                NSWorkspace.shared.open(downloadURL)
            }
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "Parrot \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError() {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = "Could not check for updates. Please check your internet connection."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
