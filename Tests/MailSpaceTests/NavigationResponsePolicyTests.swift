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

    /// Only a cancellation MailSpace can vouch for passes without a word.
    ///
    /// The regression this pins: WebKit reports a destination it *could not
    /// write* as `NSURLErrorCancelled (-999)`, the same code the app's own
    /// `cancel()` produces. Reading the code alone therefore threw away exactly
    /// the failures that need saying — an over-long filename produced no file,
    /// no dialog and no clue. So `-999` is now a failure unless this app is the
    /// one that asked for it.
    func testOnlyTheAppsOwnCancellationPassesWithoutTellingTheUser() {
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        XCTAssertFalse(NavigationPolicy.shouldReportFailure(cancelled, cancelledByApp: true))
        // The bug, in one assertion: the same error, not asked for by us.
        XCTAssertTrue(NavigationPolicy.shouldReportFailure(cancelled, cancelledByApp: false))

        // `NSUserCancelledError` is unambiguous — something asked a person and
        // they said no — and stays trusted.
        XCTAssertFalse(NavigationPolicy.shouldReportFailure(
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError), cancelledByApp: false
        ))
        XCTAssertTrue(NavigationPolicy.shouldReportFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost), cancelledByApp: false
        ))
        XCTAssertTrue(NavigationPolicy.shouldReportFailure(
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError), cancelledByApp: false
        ))
    }

    // MARK: - What a download says about itself in the log

    /// A downloaded attachment's name is mail content. `os_log` messages are
    /// world-readable on this Mac and keep for days, so a name interpolated
    /// into one marked `.public` left the app's privacy boundary for anything
    /// that runs `log show`.
    func testAFailedDownloadNeverWritesTheFilenameToTheLog() {
        let name = "Договор аренды — подпись Виталия.pdf"
        let line = NavigationPolicy.downloadFailureLine(
            filename: name,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )

        XCTAssertFalse(line.contains(name))
        XCTAssertFalse(line.contains("Договор"))
        XCTAssertFalse(line.contains("Виталия"))
        // And it is still a diagnostic: the type, the size that may be the
        // cause, and the code that used to be misread.
        XCTAssertTrue(line.contains(".pdf"))
        XCTAssertTrue(line.contains("\(name.utf8.count) bytes"))
        XCTAssertTrue(line.contains("-999"))
    }

    /// The error's own text is kept out for the same reason: a Cocoa file error
    /// spells the filename out in its message, and a URL error carries the
    /// failing URL — an attachment endpoint, ids and all.
    func testTheErrorsOwnMessageIsNotCopiedIntoTheLog() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteInvalidFileNameError,
            userInfo: [
                NSLocalizedDescriptionKey: "The file “Медкарта Иванов.pdf” could not be saved.",
                NSFilePathErrorKey: "/Users/someone/Downloads/Медкарта Иванов.pdf"
            ]
        )
        let line = NavigationPolicy.downloadFailureLine(filename: "Медкарта Иванов.pdf", error: error)

        XCTAssertFalse(line.contains("Медкарта"))
        XCTAssertFalse(line.contains("Иванов"))
        XCTAssertFalse(line.contains("/Users/"))
        XCTAssertTrue(line.contains(NSCocoaErrorDomain))
    }

    func testADownloadWithNoDestinationYetSaysSoRatherThanNothing() {
        let line = NavigationPolicy.downloadFailureLine(
            filename: nil,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        )
        XCTAssertTrue(line.contains("no destination yet"))
    }

    func testANameWithNoExtensionStillReducesToAShape() {
        XCTAssertEqual(NavigationPolicy.redactedName("счёт"), "no extension, 8 bytes")
        XCTAssertEqual(NavigationPolicy.redactedName(nil), "no destination yet")
    }

    // MARK: - The window that only ever carried a download

    /// A window opened only to carry a download has nothing to show and must
    /// go, **whatever URL it committed**.
    ///
    /// The freeze this pins: the old rule was `webView.url != nil`, and a popup
    /// whose download URL had already been set as its provisional one satisfied
    /// that while having shown nobody anything. It stayed on screen as an empty
    /// window with no way to close it — and `hasPopup(for:)` vetoes that
    /// account's tab recycling while a popup is open, so the 2.3 GB of growth
    /// this whole feature exists to prevent came straight back, silently.
    func testAPopupThatShowedNothingIsClosedWhateverItCommitted() {
        XCTAssertTrue(NavigationPolicy.shouldCloseEmptyPopup(
            isPopup: true, hasShownAPage: false, isMainFrameTarget: true
        ))
    }

    /// And the other half: a window the user is actually looking at — a print
    /// preview, a popped-out compose, a Google page opened on purpose — has
    /// finished a page of its own and is never closed by this rule, not even
    /// when a download starts inside it.
    func testAPopupThatShowedAPageIsLeftAlone() {
        XCTAssertFalse(NavigationPolicy.shouldCloseEmptyPopup(
            isPopup: true, hasShownAPage: true, isMainFrameTarget: true
        ))
    }

    func testATabIsNeverClosedByThisRule() {
        XCTAssertFalse(NavigationPolicy.shouldCloseEmptyPopup(
            isPopup: false, hasShownAPage: false, isMainFrameTarget: true
        ))
        // A subframe load is not the window's reason to exist either way.
        XCTAssertFalse(NavigationPolicy.shouldCloseEmptyPopup(
            isPopup: true, hasShownAPage: false, isMainFrameTarget: false
        ))
    }
}
