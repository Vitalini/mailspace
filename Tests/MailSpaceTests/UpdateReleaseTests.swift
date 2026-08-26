import XCTest
@testable import MailSpace

final class UpdateReleaseTests: XCTestCase {
    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func release(
        tag: String = "v1.1.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [[String: Any]] = [
            ["name": "MailSpace-1.1.0.zip", "browser_download_url": "https://example.invalid/a.zip", "size": 1234],
            ["name": "MailSpace-1.1.0.zip.sig", "browser_download_url": "https://example.invalid/a.zip.sig", "size": 88]
        ]
    ) -> Data {
        json([
            "tag_name": tag,
            "name": "MailSpace 1.1.0",
            "body": "### Fixed\n- A thing.",
            "draft": draft,
            "prerelease": prerelease,
            "assets": assets
        ])
    }

    func testReadsVersionNotesAssetAndSignature() throws {
        let parsed = try UpdateRelease.parse(release())
        XCTAssertEqual(parsed.version, SemanticVersion(1, 1, 0))
        XCTAssertEqual(parsed.tag, "v1.1.0")
        XCTAssertEqual(parsed.title, "MailSpace 1.1.0")
        XCTAssertEqual(parsed.notes, "### Fixed\n- A thing.")
        XCTAssertEqual(parsed.assetURL.absoluteString, "https://example.invalid/a.zip")
        XCTAssertEqual(parsed.signatureURL?.absoluteString, "https://example.invalid/a.zip.sig")
        XCTAssertEqual(parsed.assetSize, 1234)
    }

    /// A stray zip attached by hand must not be preferred over the build.
    func testPrefersTheExactlyNamedAsset() throws {
        let parsed = try UpdateRelease.parse(release(assets: [
            ["name": "screenshots.zip", "browser_download_url": "https://example.invalid/shots.zip", "size": 10],
            ["name": "MailSpace-1.1.0.zip", "browser_download_url": "https://example.invalid/real.zip", "size": 20],
            ["name": "MailSpace-1.1.0.zip.sig", "browser_download_url": "https://example.invalid/real.zip.sig", "size": 88]
        ]))
        XCTAssertEqual(parsed.assetURL.absoluteString, "https://example.invalid/real.zip")
        XCTAssertEqual(parsed.signatureURL?.absoluteString, "https://example.invalid/real.zip.sig")
    }

    func testMissingSignatureParsesButCarriesNoSignatureURL() throws {
        let parsed = try UpdateRelease.parse(release(assets: [
            ["name": "MailSpace-1.1.0.zip", "browser_download_url": "https://example.invalid/a.zip", "size": 1]
        ]))
        XCTAssertNil(parsed.signatureURL)
    }

    func testRejectsADraftOrPrerelease() {
        XCTAssertThrowsError(try UpdateRelease.parse(release(draft: true))) {
            XCTAssertEqual($0 as? ReleaseFeedError, .draftOrPrerelease)
        }
        XCTAssertThrowsError(try UpdateRelease.parse(release(prerelease: true))) {
            XCTAssertEqual($0 as? ReleaseFeedError, .draftOrPrerelease)
        }
    }

    func testRejectsATagThatIsNotAVersion() {
        XCTAssertThrowsError(try UpdateRelease.parse(release(tag: "nightly"))) {
            XCTAssertEqual($0 as? ReleaseFeedError, .unreadableVersion("nightly"))
        }
    }

    func testRejectsAReleaseWithNoBuildAttached() {
        XCTAssertThrowsError(try UpdateRelease.parse(release(assets: []))) {
            XCTAssertEqual($0 as? ReleaseFeedError, .noZipAsset)
        }
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try UpdateRelease.parse(Data("not json".utf8))) {
            XCTAssertEqual($0 as? ReleaseFeedError, .notJSON)
        }
    }

    func testMissingTag() {
        XCTAssertThrowsError(try UpdateRelease.parse(json(["assets": []]))) {
            XCTAssertEqual($0 as? ReleaseFeedError, .noTag)
        }
    }
}
