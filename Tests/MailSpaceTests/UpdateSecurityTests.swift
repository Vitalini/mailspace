import CryptoKit
import XCTest
@testable import MailSpace

final class UpdateSignatureTests: XCTestCase {
    private let payload = Data("a MailSpace release zip".utf8)

    private func keyPair() -> (privateKey: Curve25519.Signing.PrivateKey, publicBase64: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key, key.publicKey.rawRepresentation.base64EncodedString())
    }

    func testAGenuineSignatureVerifies() throws {
        let (key, publicBase64) = keyPair()
        let signature = try key.signature(for: payload).base64EncodedString()
        XCTAssertTrue(UpdateSecurity.verifyDetachedSignature(
            of: payload, base64Signature: signature, base64PublicKey: publicBase64
        ))
    }

    /// One flipped byte in a 15 MB download has to fail — this is the whole
    /// point of signing the archive rather than trusting the transport.
    func testATamperedPayloadFails() throws {
        let (key, publicBase64) = keyPair()
        let signature = try key.signature(for: payload).base64EncodedString()
        var tampered = payload
        tampered.append(0x21)
        XCTAssertFalse(UpdateSecurity.verifyDetachedSignature(
            of: tampered, base64Signature: signature, base64PublicKey: publicBase64
        ))
    }

    /// Someone who can serve bytes at the URL can serve their own signature too,
    /// so a signature made by any other key must be worth nothing.
    func testASignatureFromAnotherKeyFails() throws {
        let (_, publicBase64) = keyPair()
        let attacker = Curve25519.Signing.PrivateKey()
        let signature = try attacker.signature(for: payload).base64EncodedString()
        XCTAssertFalse(UpdateSecurity.verifyDetachedSignature(
            of: payload, base64Signature: signature, base64PublicKey: publicBase64
        ))
    }

    func testAnEmptyPublicKeyNeverVerifies() throws {
        let (key, _) = keyPair()
        let signature = try key.signature(for: payload).base64EncodedString()
        XCTAssertFalse(UpdateSecurity.verifyDetachedSignature(
            of: payload, base64Signature: signature, base64PublicKey: ""
        ))
    }

    func testGarbageInputsAreRejectedRatherThanCrashing() {
        XCTAssertFalse(UpdateSecurity.verifyDetachedSignature(
            of: payload, base64Signature: "not base64!!", base64PublicKey: "also not base64!!"
        ))
        XCTAssertFalse(UpdateSecurity.verifyDetachedSignature(
            of: payload,
            base64Signature: Data(repeating: 0, count: 64).base64EncodedString(),
            base64PublicKey: Data(repeating: 0, count: 8).base64EncodedString()
        ))
    }

    func testSurroundingWhitespaceIsToleratedInTheSignatureFile() throws {
        let (key, publicBase64) = keyPair()
        let signature = try key.signature(for: payload).base64EncodedString()
        XCTAssertTrue(UpdateSecurity.verifyDetachedSignature(
            of: payload, base64Signature: "\n" + signature + "\n", base64PublicKey: publicBase64
        ))
    }
}

final class DesignatedRequirementTests: XCTestCase {
    /// The Swift constant and the file `make smoke` and `scripts/release.sh`
    /// compare the built app against must be the same string. If they drift,
    /// the app would happily install a bundle the release gate rejects, or
    /// refuse the one it accepts.
    func testTheSwiftConstantMatchesTheCheckedInRequirement() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MailSpaceTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let path = repoRoot.appendingPathComponent("scripts/expected-requirement.txt")
        let onDisk = try String(contentsOf: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(onDisk, UpdateSecurity.designatedRequirement)
    }

    func testTheRequirementPinsBothIdentifierAndCertificate() {
        XCTAssertTrue(UpdateSecurity.designatedRequirement.contains("identifier \"com.vitalii.MailSpace\""))
        XCTAssertTrue(UpdateSecurity.designatedRequirement.contains("certificate root"))
    }
}

final class InstallLocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester")

    func testApplicationsIsUpdatable() {
        XCTAssertTrue(InstallLocation.isSelfUpdatable(
            bundle: URL(fileURLWithPath: "/Applications/MailSpace.app"), home: home
        ))
    }

    func testUserApplicationsIsUpdatable() {
        XCTAssertTrue(InstallLocation.isSelfUpdatable(
            bundle: URL(fileURLWithPath: "/Users/tester/Applications/MailSpace.app"), home: home
        ))
    }

    /// `make run` launches this one. Self-updating it would overwrite the
    /// working copy in the repository with a downloaded release.
    func testTheRepositoryBuildIsNotUpdatable() {
        XCTAssertFalse(InstallLocation.isSelfUpdatable(
            bundle: URL(fileURLWithPath: "/Users/tester/projects/mailspace/build/MailSpace.app"), home: home
        ))
    }

    func testANestedApplicationsFolderIsNotUpdatable() {
        XCTAssertFalse(InstallLocation.isSelfUpdatable(
            bundle: URL(fileURLWithPath: "/Applications/Utilities/MailSpace.app"), home: home
        ))
        XCTAssertFalse(InstallLocation.isSelfUpdatable(
            bundle: URL(fileURLWithPath: "/Volumes/Backup/Applications/MailSpace.app"), home: home
        ))
    }

    func testTrailingSlashesAndDotSegmentsDoNotFoolIt() {
        XCTAssertTrue(InstallLocation.isSelfUpdatable(
            bundle: URL(fileURLWithPath: "/Applications/./MailSpace.app"), home: home
        ))
    }
}
