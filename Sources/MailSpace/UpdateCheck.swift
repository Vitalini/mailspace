import Foundation

/// What a check found. Three outcomes, because "nothing happened" and "nothing
/// could be found out" are different answers and a manual check has to tell
/// them apart — a check that silently does nothing looks broken.
enum UpdateCheckResult {
    case available(UpdateRelease)
    case upToDate(current: SemanticVersion, latest: SemanticVersion)
    case failed(UpdateCheckFailure)
}

/// A check that could not complete. `summary` is the sentence the user reads;
/// `detail` is what goes to the log and to the alert's expanded text.
struct UpdateCheckFailure: Error, Equatable {
    let summary: String
    let detail: String
}

enum UpdateCheck {
    /// Turns an HTTP answer into a result. Pure: every branch below is a real
    /// thing GitHub does, and none of them may be reported as "you are up to
    /// date".
    ///
    /// The 404 branch is the one that matters most here. While the repository is
    /// private, an unauthenticated request gets 404 — indistinguishable from "no
    /// release yet" unless the app says which it is, and a broken feed that
    /// reads as "up to date" is a silent failure by design.
    static func classify(
        status: Int,
        body: Data?,
        currentVersion: SemanticVersion
    ) -> UpdateCheckResult {
        switch status {
        case 200:
            guard let body else {
                return .failed(UpdateCheckFailure(
                    summary: "GitHub returned an empty answer.",
                    detail: "HTTP 200 with no body."
                ))
            }
            do {
                let release = try UpdateRelease.parse(body)
                if release.version > currentVersion {
                    return .available(release)
                }
                return .upToDate(current: currentVersion, latest: release.version)
            } catch let error as ReleaseFeedError {
                return .failed(UpdateCheckFailure(
                    summary: "MailSpace could not read the latest release.",
                    detail: error.description
                ))
            } catch {
                return .failed(UpdateCheckFailure(
                    summary: "MailSpace could not read the latest release.",
                    detail: error.localizedDescription
                ))
            }
        case 404:
            return .failed(UpdateCheckFailure(
                summary: "MailSpace found no releases on GitHub.",
                detail: "HTTP 404 from the releases API. Either no release has been published yet, "
                    + "or the repository is not public — an unauthenticated request cannot see a private repo."
            ))
        case 403, 429:
            return .failed(UpdateCheckFailure(
                summary: "GitHub is rate-limiting this Mac.",
                detail: "HTTP \(status) from the releases API. Unauthenticated requests are capped at "
                    + "60 per hour per IP address; try again later."
            ))
        case 500...599:
            return .failed(UpdateCheckFailure(
                summary: "GitHub is having trouble right now.",
                detail: "HTTP \(status) from the releases API."
            ))
        default:
            return .failed(UpdateCheckFailure(
                summary: "GitHub answered in a way MailSpace did not expect.",
                detail: "HTTP \(status) from the releases API."
            ))
        }
    }

    /// A transport failure — no network, DNS, TLS — phrased for the person who
    /// clicked the menu item rather than for a log reader.
    static func transportFailure(_ error: Error) -> UpdateCheckFailure {
        let code = (error as NSError).code
        let offline = code == NSURLErrorNotConnectedToInternet
            || code == NSURLErrorNetworkConnectionLost
            || code == NSURLErrorCannotFindHost
            || code == NSURLErrorTimedOut
        return UpdateCheckFailure(
            summary: offline
                ? "MailSpace could not reach GitHub."
                : "The update check failed.",
            detail: error.localizedDescription
        )
    }
}

/// Fetches the feed. The only part of the check that touches the network.
final class UpdateChecker {
    private let feedURL: URL
    private let session: URLSession

    init(feedURL: URL) {
        self.feedURL = feedURL
        let configuration = URLSessionConfiguration.ephemeral
        // A check must never serve a cached answer: he clicks "Check for
        // Updates…" precisely when he has just published one.
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func check(currentVersion: SemanticVersion, completion: @escaping (UpdateCheckResult) -> Void) {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MailSpace/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            let result: UpdateCheckResult
            if let error {
                result = .failed(UpdateCheck.transportFailure(error))
            } else if let http = response as? HTTPURLResponse {
                result = UpdateCheck.classify(status: http.statusCode, body: data, currentVersion: currentVersion)
            } else {
                result = .failed(UpdateCheckFailure(
                    summary: "The update check failed.",
                    detail: "No HTTP response from \(self.feedURL.absoluteString)."
                ))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
