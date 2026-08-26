import Foundation

/// One published GitHub release, reduced to the five things the updater needs.
struct UpdateRelease: Equatable {
    let version: SemanticVersion
    let tag: String
    let title: String
    /// The release body, as Markdown. Rendered by `ReleaseNotes`.
    let notes: String
    let assetURL: URL
    /// The detached Ed25519 signature over `assetURL`'s bytes. Optional in the
    /// type only so a malformed release produces a clear refusal at install
    /// time rather than a parse failure that reads like "GitHub is down".
    let signatureURL: URL?
    let assetSize: Int
}

enum ReleaseFeedError: Error, Equatable, CustomStringConvertible {
    case notJSON
    case noTag
    case unreadableVersion(String)
    case draftOrPrerelease
    case noZipAsset

    var description: String {
        switch self {
        case .notJSON:
            return "GitHub's answer was not the release JSON this app expects."
        case .noTag:
            return "The latest release has no tag name."
        case .unreadableVersion(let tag):
            return "The latest release is tagged “\(tag)”, which is not a version number."
        case .draftOrPrerelease:
            return "The latest release is still a draft or a pre-release."
        case .noZipAsset:
            return "The latest release has no .zip asset to download."
        }
    }
}

extension UpdateRelease {
    /// Reads `GET /repos/:owner/:repo/releases/latest`.
    ///
    /// Pure, so every shape GitHub can return — a draft, a tag that is not a
    /// version, a release someone published without attaching the build — is a
    /// test rather than something discovered on the one day an update matters.
    static func parse(_ data: Data) throws -> UpdateRelease {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ReleaseFeedError.notJSON
        }
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true {
            throw ReleaseFeedError.draftOrPrerelease
        }
        guard let tag = root["tag_name"] as? String, !tag.isEmpty else {
            throw ReleaseFeedError.noTag
        }
        guard let version = SemanticVersion(tag) else {
            throw ReleaseFeedError.unreadableVersion(tag)
        }

        let assets = (root["assets"] as? [[String: Any]]) ?? []
        let named: [(name: String, url: URL, size: Int)] = assets.compactMap { asset in
            guard
                let name = asset["name"] as? String,
                let raw = asset["browser_download_url"] as? String,
                let url = URL(string: raw)
            else { return nil }
            return (name, url, (asset["size"] as? Int) ?? 0)
        }

        // The build, then its detached signature. Preferring the exact
        // `MailSpace-<version>.zip` keeps a stray zip someone attached by hand
        // from being installed in its place.
        let preferred = "MailSpace-\(version).zip"
        guard let zip = named.first(where: { $0.name == preferred })
            ?? named.first(where: { $0.name.hasSuffix(".zip") })
        else {
            throw ReleaseFeedError.noZipAsset
        }
        let signature = named.first { $0.name == zip.name + ".sig" }?.url

        let title = (root["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "MailSpace \(version)"
        return UpdateRelease(
            version: version,
            tag: tag,
            title: title,
            notes: (root["body"] as? String) ?? "",
            assetURL: zip.url,
            signatureURL: signature,
            assetSize: zip.size
        )
    }
}
