import WebKit
import XCTest
@testable import MailSpace

/// Show it or save it — the predicate the "I click and nothing" bug lived in.
///
/// The old rule was `canShowMIMEType ? .allow : .download`, which never reads
/// `Content-Disposition`. `canShowMIMEType` is true for PDFs, images, text and
/// HTML *even when the server said `attachment`*, so the attachments a person
/// downloads most often were rendered instead of saved — and Gmail renders them
/// into a hidden frame, where that is indistinguishable from nothing happening.
final class NavigationResponsePolicyTests: XCTestCase {
    // MARK: - Reading the header

    func testTheServerSayingAttachmentIsRecognised() {
        for header in [
            "attachment",
            "attachment; filename=\"report.pdf\"",
            "ATTACHMENT; filename=report.pdf",
            "  attachment ; filename*=UTF-8''report.pdf"
        ] {
            XCTAssertTrue(NavigationPolicy.isAttachment(contentDisposition: header), header)
        }
    }

    func testAnythingElseIsNotAnAttachment() {
        for header in [
            "inline",
            "inline; filename=\"report.pdf\"",
            // The reason this is parsed rather than searched for.
            "inline; filename=\"attachment plan.pdf\"",
            "form-data; name=\"file\"",
            ""
        ] {
            XCTAssertFalse(NavigationPolicy.isAttachment(contentDisposition: header), header)
        }
        XCTAssertFalse(NavigationPolicy.isAttachment(contentDisposition: nil))
    }

    // MARK: - The decision

    /// The regression itself: a PDF WebKit is perfectly able to render, which
    /// the server nonetheless asked to be saved.
    func testARenderableAttachmentIsSavedRatherThanShown() {
        XCTAssertEqual(
            NavigationPolicy.responsePolicy(isAttachment: true, canShowMIMEType: true),
            .download
        )
    }

    /// And the other half: a PDF nobody asked to save still opens.
    func testARenderableResponseWithNoDispositionIsShown() {
        XCTAssertEqual(
            NavigationPolicy.responsePolicy(isAttachment: false, canShowMIMEType: true),
            .allow
        )
    }

    /// The one case that always worked, which is why the bug survived: a zip.
    func testSomethingWebKitCannotRenderIsAlwaysSaved() {
        XCTAssertEqual(
            NavigationPolicy.responsePolicy(isAttachment: false, canShowMIMEType: false),
            .download
        )
        XCTAssertEqual(
            NavigationPolicy.responsePolicy(isAttachment: true, canShowMIMEType: false),
            .download
        )
    }

    /// End to end over the header, on a response of the shape Gmail's
    /// attachment host actually returns.
    func testTheRuleReadsARealResponse() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://mail-attachment.googleusercontent.com/attachment/u/0/")),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/pdf",
                "Content-Disposition": "attachment; filename=\"report.pdf\""
            ]
        ))
        XCTAssertTrue(
            NavigationPolicy.isAttachment(
                contentDisposition: response.value(forHTTPHeaderField: "Content-Disposition")
            )
        )
    }

    // MARK: - Failure is never silent

    /// The app cancelling its own downloads (account removal) must not put a
    /// dialog up; anything else must.
    func testOnlyACancellationPassesWithoutTellingTheUser() {
        XCTAssertTrue(NavigationPolicy.isCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ))
        XCTAssertTrue(NavigationPolicy.isCancellation(
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        ))
        XCTAssertFalse(NavigationPolicy.isCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        ))
        XCTAssertFalse(NavigationPolicy.isCancellation(
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        ))
    }

    /// A window opened only to carry a download has nothing to show and must go
    /// — the empty popup left behind after every `target="_blank"` download.
    func testAPopupWithNothingInItIsClosed() {
        XCTAssertTrue(NavigationPolicy.shouldCloseEmptyPopup(
            isPopup: true, hasRenderedAPage: false, isMainFrameTarget: true
        ))
        XCTAssertFalse(NavigationPolicy.shouldCloseEmptyPopup(
            isPopup: true, hasRenderedAPage: true, isMainFrameTarget: true
        ))
        XCTAssertFalse(NavigationPolicy.shouldCloseEmptyPopup(
            isPopup: false, hasRenderedAPage: false, isMainFrameTarget: true
        ))
    }
}
