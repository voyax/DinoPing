import Foundation

/// A newer release found on GitHub.
struct AppUpdate: Equatable {
    let version: String   // normalized, no leading "v"
    let name: String
    let notes: String     // release body (markdown)
    let pageURL: URL      // the release's html_url, opened to download
}

/// Checks GitHub Releases for a newer version. No code signing required — we
/// only notify and link to the download page (no in-place install à la
/// Sparkle, which would need a signed + notarized build).
@MainActor
@Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppUpdate)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private var lastCheck: Date?

    private let skipKey = "AgentPulse.skippedUpdateVersion"

    /// `auto` (launch/background) checks stay silent on "up to date" and on
    /// errors, and throttle to once an hour. A user-initiated check always
    /// runs and surfaces every outcome.
    func check(auto: Bool = false) async {
        guard let repo = AppInfo.githubRepo, !repo.isEmpty else {
            if !auto { status = .failed("No update channel configured yet.") }
            return
        }
        if auto, let last = lastCheck, Date.now.timeIntervalSince(last) < 3600 { return }
        if !auto { status = .checking }
        lastCheck = .now

        do {
            let update = try await fetchLatest(repo: repo)
            if update.version.compare(AppInfo.version, options: .numeric) == .orderedDescending {
                status = .available(update)
            } else if !auto {
                status = .upToDate
            }
        } catch {
            if !auto { status = .failed("Couldn't reach GitHub. Check your connection.") }
        }
    }

    var skippedVersion: String? { UserDefaults.standard.string(forKey: skipKey) }

    func skip(_ version: String) {
        UserDefaults.standard.set(version, forKey: skipKey)
    }

    private func fetchLatest(repo: String) async throws -> AppUpdate {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let tag = json["tag_name"] as? String ?? ""
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let urlString = json["html_url"] as? String ?? ""
        guard !version.isEmpty, let pageURL = URL(string: urlString) else {
            throw URLError(.cannotParseResponse)
        }
        return AppUpdate(
            version: version,
            name: json["name"] as? String ?? tag,
            notes: json["body"] as? String ?? "",
            pageURL: pageURL
        )
    }
}
