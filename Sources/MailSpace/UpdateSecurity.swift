import CryptoKit
import Foundation
import Security

enum UpdateSecurityError: Error, CustomStringConvertible {
    case noPublicKey
    case noSignatureAsset
    case badSignature
    case unreadableRequirement(OSStatus)
    case unreadableBundle(OSStatus)
    case signatureMismatch(OSStatus, String)
    case wrongBundleIdentifier(String)
    case wrongVersion(expected: String, found: String)

    var description: String {
        switch self {
        case .noPublicKey:
            return "This build carries no update public key (MSUpdatePublicKey is empty), "
                + "so it cannot tell a real MailSpace release from anything else. Install by hand."
        case .noSignatureAsset:
            return "The release has no detached signature (.zip.sig) next to its download."
        case .badSignature:
            return "The download is not signed by MailSpace's update key. Nothing was installed."
        case .unreadableRequirement(let status):
            return "MailSpace could not build its own signing requirement (OSStatus \(status))."
        case .unreadableBundle(let status):
            return "The downloaded app has no readable code signature (OSStatus \(status))."
        case .signatureMismatch(let status, let message):
            return "The downloaded app is not signed by the certificate this copy of MailSpace "
                + "was signed with: \(message) (OSStatus \(status)). Nothing was installed."
        case .wrongBundleIdentifier(let found):
            return "The downloaded app identifies itself as “\(found)”, not MailSpace."
        case .wrongVersion(let expected, let found):
            return "The release says \(expected) but the app inside it is \(found)."
        }
    }
}

enum UpdateSecurity {
    /// The signature every installable download must satisfy, byte for byte.
    ///
    /// Pinned to the leaf certificate, not to a team ID — there is no Apple
    /// Developer identity here, so "MailSpace Self-Signed" *is* the root of
    /// trust. Kept in sync with `scripts/expected-requirement.txt` by a unit
    /// test and by `make smoke`, so rotating the certificate is a deliberate
    /// source change rather than a discovery made after a release has stranded
    /// every installed copy.
    static let designatedRequirement =
        "identifier \"com.vitalii.MailSpace\" and certificate root = H\"f5cf6d1c83884c6114eb7bc4b147d71c093f7645\""

    static let bundleIdentifier = "com.vitalii.MailSpace"

    // MARK: - Detached signature over the download

    /// Ed25519 over the exact bytes that were downloaded.
    ///
    /// This is the half TLS cannot give: GitHub, a proxy, or anyone who can
    /// serve bytes at that URL can change the zip, and only the holder of the
    /// private key can produce a signature for it.
    static func verifyDetachedSignature(
        of payload: Data,
        base64Signature: String,
        base64PublicKey: String
    ) -> Bool {
        let cleanedKey = base64PublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedSignature = base64Signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !cleanedKey.isEmpty,
            let keyData = Data(base64Encoded: cleanedKey), keyData.count == 32,
            let signature = Data(base64Encoded: cleanedSignature), signature.count == 64,
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(signature, for: payload)
    }

    // MARK: - Code signature of what was extracted

    /// Checks the extracted bundle against `designatedRequirement`, nested code
    /// and all architectures included.
    ///
    /// The signature check and the detached signature are not redundant: the
    /// first proves the zip came from the release that was signed, the second
    /// proves the app inside it was built and signed on the Mac that holds the
    /// certificate. Either one failing stops the install.
    static func verifyCodeSignature(of bundle: URL) throws {
        var requirement: SecRequirement?
        var status = SecRequirementCreateWithString(designatedRequirement as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw UpdateSecurityError.unreadableRequirement(status)
        }

        var staticCode: SecStaticCode?
        status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw UpdateSecurityError.unreadableBundle(status)
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else {
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "code signature rejected"
            throw UpdateSecurityError.signatureMismatch(status, message)
        }
    }

    /// The staged bundle must also say it is the same app, at the version the
    /// release claims. Catches a correctly signed but wrongly assembled zip.
    static func verifyIdentity(of bundle: URL, expecting version: SemanticVersion) throws {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        let contents = (try? Data(contentsOf: plist))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let identifier = (contents?["CFBundleIdentifier"] as? String) ?? ""
        guard identifier == bundleIdentifier else {
            throw UpdateSecurityError.wrongBundleIdentifier(identifier.isEmpty ? "nothing" : identifier)
        }
        let shortVersion = (contents?["CFBundleShortVersionString"] as? String) ?? ""
        guard let staged = SemanticVersion(shortVersion), staged == version else {
            throw UpdateSecurityError.wrongVersion(expected: version.description, found: shortVersion.isEmpty ? "unset" : shortVersion)
        }
    }
}

/// Where the running copy lives, and therefore whether it may replace itself.
///
/// Refusing anywhere else is what keeps `make run` from quietly overwriting the
/// working copy in the repo — and keeps the app from ever needing to write into
/// a directory that would raise an authentication prompt.
enum InstallLocation {
    /// `/Applications` and `~/Applications` are both group- or user-writable on
    /// this Mac, so replacing a bundle in either needs no administrator rights.
    static func isSelfUpdatable(bundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let parent = bundle.standardizedFileURL.deletingLastPathComponent().standardizedFileURL.path
        let allowed = [
            "/Applications",
            home.standardizedFileURL.appendingPathComponent("Applications").path
        ]
        return allowed.contains(parent)
    }
}
