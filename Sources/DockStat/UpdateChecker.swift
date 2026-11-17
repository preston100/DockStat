import Foundation
import Combine

/// Asks GitHub, at most once a day, whether a newer release exists. Sends nothing but a
/// plain request for the public "latest release" page; turn it off in Settings.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repo = "preston100/DockStat"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }

    @Published private(set) var availableVersion: String?
    @Published private(set) var releaseURL: URL?

    private let lastCheckKey = "lastUpdateCheck"
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks now if a day has passed, then keeps checking daily while the app runs.
    func start() {
        checkIfDue()
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkIfDue() {
        guard AppSettings.shared.checkForUpdates else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        check()
    }

    func check() {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DockStat", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)
                if Self.isNewer(latest, than: self.currentVersion) {
                    self.availableVersion = latest
                    self.releaseURL = page ?? Self.releasesPage
                } else {
                    self.availableVersion = nil
                }
            }
        }.resume()
    }

    /// Compares dotted version numbers: 1.10.0 > 1.9.2.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
