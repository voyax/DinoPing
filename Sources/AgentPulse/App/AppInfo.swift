import Foundation

/// Single source of truth for version + legal metadata shown in About.
///
/// Version/build read from the bundle's Info.plist when packaged, falling back
/// to the constants here when running as a bare `swift build` binary (which has
/// no Info.plist). Keep the fallbacks in sync with the root `VERSION` file.
enum AppInfo {
    static let displayName = "DinoPing"

    static let version: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"

    static let build: String =
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    static let copyright = "© 2026 voya. All rights reserved."

    /// `owner/repo` for the GitHub Releases update feed; `nil` disables update
    /// checks. TODO: replace OWNER with your GitHub username/org, then create the
    /// repo, push, and publish tagged releases (e.g. `v0.2.0`) with notes.
    static let githubRepo: String? = "OWNER/DinoPing"

    /// Public links. `nil` until the product has a real home — About hides any
    /// button whose URL is nil rather than pointing at a 404.
    static let websiteURL: URL? = nil
    static let issuesURL: URL? = nil

    /// Shown verbatim in the About → License sheet. Mirrors the root LICENSE.
    static let licenseText = """
    Copyright © 2026 voya. All rights reserved.

    This software and its source code are proprietary and confidential. \
    Unauthorized copying, modification, distribution, or use of this software, \
    in whole or in part, via any medium, is strictly prohibited without the \
    express written permission of the copyright holder.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
    """
}
