import XCTest
@testable import ypower

final class NetworkQualityEvaluatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testDegradesAfterSixtySecondsOfSustainedWeakness() {
        let evaluator = NetworkQualityEvaluator()
        var state: ConnectionState = .unknown
        for i in 0...12 {
            state = evaluator.record(isWeak: true, now: start.addingTimeInterval(Double(i) * 5))
        }
        XCTAssertEqual(state, .degraded)
    }

    func testDoesNotDegradeBeforeWindowIsFull() {
        let evaluator = NetworkQualityEvaluator()
        var state: ConnectionState = .unknown
        for i in 0...9 {
            state = evaluator.record(isWeak: true, now: start.addingTimeInterval(Double(i) * 5))
        }
        XCTAssertNotEqual(state, .degraded)
    }

    func testMomentaryBlipDoesNotDegrade() {
        let evaluator = NetworkQualityEvaluator()
        var state: ConnectionState = .unknown
        for i in 0...12 {
            let isWeak = i == 6
            state = evaluator.record(isWeak: isWeak, now: start.addingTimeInterval(Double(i) * 5))
        }
        XCTAssertNotEqual(state, .degraded)
    }

    func testRecoveryClearsDegradedState() {
        let evaluator = NetworkQualityEvaluator()
        for i in 0...12 {
            _ = evaluator.record(isWeak: true, now: start.addingTimeInterval(Double(i) * 5))
        }
        XCTAssertEqual(evaluator.state, .degraded)

        var state: ConnectionState = .degraded
        for i in 13...25 {
            state = evaluator.record(isWeak: false, now: start.addingTimeInterval(Double(i) * 5))
        }
        XCTAssertEqual(state, .good)
    }

    func testCooldownPreventsRefiringSameReason() {
        let evaluator = NetworkQualityEvaluator()
        for i in 0...12 {
            _ = evaluator.record(isWeak: true, now: start.addingTimeInterval(Double(i) * 5))
        }
        let t1 = start.addingTimeInterval(65)
        XCTAssertTrue(evaluator.shouldNotify(reason: "wifi-weak", now: t1))

        let t2 = t1.addingTimeInterval(10)
        XCTAssertFalse(evaluator.shouldNotify(reason: "wifi-weak", now: t2))

        let t3 = t1.addingTimeInterval(601)
        XCTAssertTrue(evaluator.shouldNotify(reason: "wifi-weak", now: t3))
    }

    func testResetClearsWindowAndState() {
        let evaluator = NetworkQualityEvaluator()
        for i in 0...12 {
            _ = evaluator.record(isWeak: true, now: start.addingTimeInterval(Double(i) * 5))
        }
        evaluator.reset()
        XCTAssertEqual(evaluator.state, .unknown)
        XCTAssertFalse(evaluator.shouldNotify(reason: "wifi-weak", now: start.addingTimeInterval(1000)))
    }
}
