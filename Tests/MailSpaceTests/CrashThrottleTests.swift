import XCTest
@testable import MailSpace

final class CrashThrottleTests: XCTestCase {
    private let key = ObjectIdentifier(NSObject.self)
    private let other = ObjectIdentifier(NSString.self)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testReloadsUpToTheLimitThenStops() {
        var throttle = CrashThrottle(limit: 3, window: 60)

        XCTAssertEqual((0..<5).map { throttle.shouldReload(key, now: start.addingTimeInterval(Double($0))) },
                       [true, true, true, false, false])
    }

    func testBurstAgesOutAfterTheWindow() {
        var throttle = CrashThrottle(limit: 2, window: 60)
        XCTAssertTrue(throttle.shouldReload(key, now: start))
        XCTAssertTrue(throttle.shouldReload(key, now: start))
        XCTAssertFalse(throttle.shouldReload(key, now: start))

        XCTAssertTrue(throttle.shouldReload(key, now: start.addingTimeInterval(61)))
    }

    func testWebViewsAreCountedSeparately() {
        var throttle = CrashThrottle(limit: 1, window: 60)
        XCTAssertTrue(throttle.shouldReload(key, now: start))
        XCTAssertFalse(throttle.shouldReload(key, now: start))

        XCTAssertTrue(throttle.shouldReload(other, now: start))
    }

    func testForgetClearsTheBurst() {
        var throttle = CrashThrottle(limit: 1, window: 60)
        XCTAssertTrue(throttle.shouldReload(key, now: start))
        XCTAssertFalse(throttle.shouldReload(key, now: start))

        throttle.forget(key)

        XCTAssertTrue(throttle.shouldReload(key, now: start))
    }
}
