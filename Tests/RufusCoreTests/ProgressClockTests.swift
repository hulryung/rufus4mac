import XCTest
@testable import RufusCore

final class ProgressClockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testNothingBeforeStart() {
        let c = ProgressClock()
        XCTAssertNil(c.elapsed(at: at(10)))
        XCTAssertNil(c.remaining(at: at(10)))
    }

    func testElapsedRunsFromStart() {
        var c = ProgressClock()
        c.start(at: t0)
        XCTAssertEqual(try XCTUnwrap(c.elapsed(at: at(42))), 42, accuracy: 0.001)
    }

    /// An estimate from one or two samples is noise, so hold it back until the phase has run a
    /// few seconds and moved a little.
    func testNoEstimateUntilThereIsEnoughToExtrapolateFrom() {
        var c = ProgressClock()
        c.start(at: t0)
        c.observe(phase: "copying", fraction: 0, at: t0)
        c.observe(phase: "copying", fraction: 0.5, at: at(1))
        XCTAssertNil(c.remaining(at: at(1)), "too early in the phase")

        var d = ProgressClock()
        d.start(at: t0)
        d.observe(phase: "copying", fraction: 0, at: t0)
        d.observe(phase: "copying", fraction: 0.001, at: at(10))
        XCTAssertNil(d.remaining(at: at(10)), "too little progress")
    }

    /// The first observation of a phase only sets the baseline; a rate needs a second one.
    func testEstimatesFromTheObservedRate() throws {
        var c = ProgressClock()
        c.start(at: t0)
        c.observe(phase: "copying", fraction: 0, at: t0)
        XCTAssertNil(c.remaining(at: t0), "one sample is not a rate")
        // A quarter of the phase in 10s implies 30s more for the remaining three quarters.
        c.observe(phase: "copying", fraction: 0.25, at: at(10))
        XCTAssertEqual(try XCTUnwrap(c.remaining(at: at(10))), 30, accuracy: 0.001)
    }

    /// The Windows path runs "copying" 0…1 and then "splitting" 0…1 again. Carrying the copy's rate
    /// into the split would make the estimate leap; the phase change resets the baseline.
    func testPhaseChangeRestartsTheEstimate() throws {
        var c = ProgressClock()
        c.start(at: t0)
        c.observe(phase: "copying", fraction: 1, at: at(100))
        c.observe(phase: "splitting", fraction: 0, at: at(100))
        XCTAssertNil(c.remaining(at: at(101)), "the new phase has no rate yet")
        // 0.5 of the split in 10s leaves 10s, regardless of how long copying took.
        c.observe(phase: "splitting", fraction: 0.5, at: at(110))
        XCTAssertEqual(try XCTUnwrap(c.remaining(at: at(110))), 10, accuracy: 0.001,
                       "estimate must come from the split's own rate, not the copy's")
    }

    /// A phase that starts partway through (progress already reported) must measure from there.
    func testEstimateMeasuresFromThePhaseStartFraction() throws {
        var c = ProgressClock()
        c.start(at: t0)
        c.observe(phase: "verifying", fraction: 0.4, at: at(5))
        c.observe(phase: "verifying", fraction: 0.6, at: at(15))
        // 0.2 of the phase took 10s, so the remaining 0.4 needs 20s.
        XCTAssertEqual(try XCTUnwrap(c.remaining(at: at(15))), 20, accuracy: 0.001)
    }

    func testNoEstimateOnceComplete() {
        var c = ProgressClock()
        c.start(at: t0)
        c.observe(phase: "copying", fraction: 1, at: at(20))
        XCTAssertNil(c.remaining(at: at(20)))
    }

    func testFinishFreezesElapsed() throws {
        var c = ProgressClock()
        c.start(at: t0)
        c.observe(phase: "copying", fraction: 0.5, at: at(10))
        c.finish(at: at(30))
        XCTAssertEqual(try XCTUnwrap(c.elapsed(at: at(999))), 30, accuracy: 0.001)
        XCTAssertNil(c.remaining(at: at(999)))
        c.observe(phase: "copying", fraction: 0.9, at: at(999))
        XCTAssertEqual(try XCTUnwrap(c.elapsed(at: at(999))), 30, accuracy: 0.001,
                       "a late callback must not restart a finished clock")
    }

    func testRestartClearsTheFinishedTotal() throws {
        var c = ProgressClock()
        c.start(at: t0); c.finish(at: at(30))
        c.start(at: at(100))
        XCTAssertEqual(try XCTUnwrap(c.elapsed(at: at(140))), 40, accuracy: 0.001)
    }

    func testFormatsMinutesAndHours() {
        XCTAssertEqual(ProgressClock.format(0), "0:00")
        XCTAssertEqual(ProgressClock.format(9), "0:09")
        XCTAssertEqual(ProgressClock.format(247), "4:07")
        XCTAssertEqual(ProgressClock.format(3600), "1:00:00")
        XCTAssertEqual(ProgressClock.format(3750), "1:02:30")
        XCTAssertEqual(ProgressClock.format(-5), "0:00", "a negative interval must not render oddly")
    }
}
