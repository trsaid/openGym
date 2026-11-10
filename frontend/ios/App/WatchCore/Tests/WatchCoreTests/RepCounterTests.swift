import XCTest
@testable import WatchCore

/// The rep counter on made-up wrist signals: what a rep is, what is not one, and when a set is over.
final class RepCounterTests: XCTestCase {

    func assertCount(_ got: Int, about want: Int, slack: Int = 1, _ what: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(abs(got - want) <= slack, "\(what) counted \(got), expected \(want)", file: file, line: line)
    }

    /* ---------- lifts as the laws of motion make them ---------- */

    func testRepsCountOnceWhetherTheyRunTogetherOrPause() {
        XCTAssertEqual(RepSignals.count(RepSignals.lift(10)), 10, "a steady bench press, no pause")
        XCTAssertEqual(RepSignals.count(RepSignals.lift(10, bottom: 0.5)), 10, "a pause on the chest")
        XCTAssertEqual(RepSignals.count(RepSignals.lift(10, top: 0.8)), 10, "a pause at lockout")
        XCTAssertEqual(RepSignals.count(RepSignals.lift(12, up: 0.8, down: 0.8, travel: 0.5)), 12, "quick curls")
        XCTAssertEqual(RepSignals.count(RepSignals.lift(15, up: 0.5, down: 0.5, travel: 0.3)), 15, "fast and short")
    }

    func testASlowWayDownIsStillOneRep() {
        // Lowered in 3 or 4 seconds the weight hardly accelerates at all: the turn at the top
        // is what counts, not the two faint ends of the way down.
        XCTAssertEqual(RepSignals.count(RepSignals.lift(8, up: 2, down: 3)), 8)
        XCTAssertEqual(RepSignals.count(RepSignals.lift(6, up: 2, down: 4, top: 1, bottom: 1)), 6)
    }

    func testHeavyRepsWithABreathBetweenCount() {
        XCTAssertEqual(RepSignals.count(RepSignals.lift(5, up: 1.5, down: 1.5, top: 0.5, bottom: 3, travel: 0.6)), 5, "deadlifts, reset on the floor")
        XCTAssertEqual(RepSignals.count(RepSignals.lift(8, up: 1.2, down: 1.8, top: 1.5, travel: 0.55)), 8, "squats, a breath standing")
    }

    func testAShortRangeOfMotionCounts() {
        XCTAssertEqual(RepSignals.count(RepSignals.lift(10, travel: 0.1)), 10)
    }

    func testFourHundredLiftsOfEveryTempoAreWithinOneRep() {
        // Tempo, pauses, range, direction, sensor noise and how much one rep differs from the
        // next, all drawn at random (the same every run). What this guards is the method; how
        // it does on a real wrist is what the recorded sets are for.
        var dice = RepSignals.Dice(seed: 99)
        func draw(_ a: Double, _ b: Double) -> Double { a + (b - a) * dice.unit() }
        var exact = 0
        for i in 0..<400 {
            let reps = Int(draw(4, 16))
            let up = draw(0.6, 2.5), down = draw(0.8, 4)
            let top = dice.unit() < 0.5 ? 0 : draw(0.2, 1.5), bottom = dice.unit() < 0.5 ? 0 : draw(0.2, 2.5)
            let travel = draw(0.15, 0.7), sigma = draw(0.003, 0.01), jitter = draw(0, 0.25)
            let axis = (draw(-1, 1), draw(-1, 1), draw(-1, 1))
            let lift = RepSignals.lift(reps, up: up, down: down, top: top, bottom: bottom, travel: travel, lead: draw(0.5, 4), tail: 3,
                                       noise: sigma, jitter: jitter, axis: axis, seed: UInt64(i + 1))
            let got = RepSignals.count(lift)
            if got == reps { exact += 1 }
            XCTAssertTrue(abs(got - reps) <= 1, "lift \(i): \(reps) reps counted as \(got) (up \(up), down \(down), top \(top), bottom \(bottom), travel \(travel))")
        }
        XCTAssertGreaterThanOrEqual(exact, 390, "exact on \(exact) of 400")
    }

    /* ---------- bursts of movement between rests (RepCounter's own test signals) ---------- */

    func testTheStartAndTheStopOfARepCountOnce() {
        assertCount(RepSignals.count(RepSignals.reps(10)), about: 10)
    }

    func testFastAndSlowBurstsCountOnce() {
        assertCount(RepSignals.count(RepSignals.reps(10, rest: 0.5)), about: 10, "fast")
        assertCount(RepSignals.count(RepSignals.reps(8, rest: 1.6)), about: 8, "slow")
        assertCount(RepSignals.count(RepSignals.reps(6, moveHz: 1.0, rest: 3.0)), about: 6, "heavy, a breath between reps")
    }

    func testTheThresholdFollowsAGrowingMovement() {
        assertCount(RepSignals.count(RepSignals.reps(10, amplitude: 0.1, amplitudeEnd: 1.0)), about: 10)
    }

    func testTheFaintShakingOfALegDayCounts() {
        // 0.06 g bursts over sensor noise: a squat as the wrist on the bar feels it.
        assertCount(RepSignals.count(RepSignals.reps(10, amplitude: 0.06, noise: 0.01)), about: 10, slack: 2)
    }

    func testMovementCountsInAnyDirection() {
        for axis in [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (1.0, 1.0, 0.0), (0.3, -0.8, 0.5)] {
            XCTAssertEqual(RepSignals.count(RepSignals.lift(10, axis: axis)), 10, "along \(axis)")
        }
    }

    func testAFixedHandCountsByTheForearmsTiltWhenAskedTo() {
        let pushUps = RepSignals.tiltReps(10)
        XCTAssertEqual(RepSignals.count(pushUps), 0, "the general settings listen to acceleration only")
        var tilt = RepSettings.general
        tilt.accel = 0
        tilt.tilt = 1
        assertCount(RepSignals.count(pushUps, settings: tilt), about: 10)
    }

    /* ---------- what is not a rep ---------- */

    func testAStillWristCountsNothing() {
        XCTAssertEqual(RepSignals.count(RepSignals.noise(sigma: 0.01, 10)), 0)
    }

    func testAnImpactCountsNothing() {
        var samples = RepSignals.silence(5)
        samples[100].az = 3.0
        XCTAssertEqual(RepSignals.count(samples), 0)
    }

    func testOneMovementAloneCountsNothing() {
        XCTAssertEqual(RepSignals.count(RepSignals.reps(1) + RepSignals.silence(3, from: 10)), 0)
        XCTAssertEqual(RepSignals.count(RepSignals.reps(2) + RepSignals.silence(3, from: 10)), 0)
    }

    /* ---------- the rhythm ---------- */

    func testTheCountJumpsToThreeThenGoesOnLive() {
        var c = RepCounter()
        var steps: [Int] = []
        for s in RepSignals.reps(8) {
            let added = c.feed(s)
            if added > 0 { steps.append(added) }
        }
        XCTAssertEqual(steps.first, 3)
        XCTAssertTrue(steps.dropFirst().allSatisfy { $0 == 1 })
        XCTAssertTrue(c.locked)
        XCTAssertEqual(c.count, steps.reduce(0, +))
    }

    func testTheSetStartsAtTheFirstRepOfTheRhythm() {
        var c = RepCounter()
        for s in RepSignals.lift(8, lead: 3) { _ = c.feed(s) }
        // The first rep starts after the 3 s of lead and turns at its top a second later.
        XCTAssertEqual(c.burstFrom ?? 0, 4.0, accuracy: 0.6)
    }

    func testALongPauseStartsANewCount() {
        // The walk to the bar found a rhythm (4 "reps"); the set after it is the set.
        let walk = RepSignals.reps(4)
        let gap = RepSignals.silence(25, from: walk.last!.t + RepSignals.dt)
        let set = RepSignals.reps(8, from: gap.last!.t + RepSignals.dt)
        var c = RepCounter()
        for s in walk + gap { _ = c.feed(s) }
        assertCount(c.count, about: 4, "before the set")
        XCTAssertFalse(SetEnd.due(c, now: gap.last!.t, quiet: 100))
        for s in set { _ = c.feed(s) }
        assertCount(c.count, about: 8, "the set")
        XCTAssertGreaterThan(c.burstFrom ?? 0, gap.last!.t)
    }

    func testAShortPauseKeepsTheCount() {
        // A breath in the middle of the set: 5 reps, 6 s, 5 more.
        let first = RepSignals.reps(5)
        let gap = RepSignals.silence(6, from: first.last!.t + RepSignals.dt)
        let second = RepSignals.reps(5, lead: 0, from: gap.last!.t + RepSignals.dt)
        assertCount(RepSignals.count(first + gap + second), about: 10)
    }

    func testOneLateMovementAfterTheSetCountsNothing() {
        // Ten reps, then seven seconds later the bar goes back on the rack (or the wrist comes
        // up to the eyes): far off the set's tempo, and nothing follows it.
        let set = RepSignals.lift(10)
        let gap = RepSignals.silence(7, from: set.last!.t + RepSignals.dt)
        let rack = RepSignals.lift(1, lead: 0, tail: 3, from: gap.last!.t + RepSignals.dt)
        XCTAssertEqual(RepSignals.count(set + gap + rack), 10)
    }

    func testARepAfterABreathCountsOnceTheNextOneFollows() {
        let first = RepSignals.lift(6)
        let gap = RepSignals.silence(7, from: first.last!.t + RepSignals.dt)
        let second = RepSignals.lift(2, lead: 0, tail: 2, from: gap.last!.t + RepSignals.dt)
        var c = RepCounter()
        for s in first + gap { _ = c.feed(s) }
        XCTAssertEqual(c.count, 6)
        var steps: [Int] = []
        for s in second { let n = c.feed(s); if n > 0 { steps.append(n) } }
        XCTAssertEqual(steps, [2], "the rep after the breath waits for the one after it")
        XCTAssertEqual(c.count, 8)
    }

    func testASlowerRhythmAfterAQuickOneIsTheSet() {
        // A quick rhythm (the walk to the bench, dumbbells in hand), five seconds to lie down,
        // then ten slow presses: the presses are the set, the walk is forgotten.
        let walk = RepSignals.reps(6)
        let gap = RepSignals.silence(5, from: walk.last!.t + RepSignals.dt)
        let set = RepSignals.lift(10, up: 1.5, down: 2.0, lead: 0, tail: 2, from: gap.last!.t + RepSignals.dt)
        var c = RepCounter()
        for s in walk + gap { _ = c.feed(s) }
        assertCount(c.count, about: 6, "the walk")
        for s in set { _ = c.feed(s) }
        XCTAssertEqual(c.count, 10)
        XCTAssertGreaterThan(c.burstFrom ?? 0, gap.last!.t)
    }

    func testThePauseThatStartsANewCountGrowsWithTheTempo() {
        let quick = RepCounter()
        XCTAssertEqual(quick.stale(at: 1.2), 8)
        XCTAssertEqual(quick.stale(at: 3), 12)
        XCTAssertEqual(quick.stale(at: 8), 20)
        XCTAssertEqual(quick.stale(at: nil), 8)
        // Nine seconds in a set of slow reps is a breath; in a set of quick ones it is a new set.
        func two(_ make: (Int, Double, Double) -> [MotionSample]) -> Int {
            let a = make(6, 1.0, 0)
            let gap = RepSignals.silence(9, from: a.last!.t + RepSignals.dt)
            return RepSignals.count(a + gap + make(6, 0, gap.last!.t + RepSignals.dt))
        }
        XCTAssertEqual(two { RepSignals.lift($0, up: 1.2, down: 1.8, lead: $1, from: $2) }, 12)
        XCTAssertEqual(two { RepSignals.lift($0, up: 0.6, down: 0.6, lead: $1, from: $2) }, 6)
    }

    /* ---------- a set that ends by itself ---------- */

    func testTheSetIsOverAfterFourQuietSeconds() {
        let set = RepSignals.reps(10)
        let end = set.last!.t
        var c = RepCounter()
        for s in set { _ = c.feed(s) }
        var overAt: Double?
        for s in RepSignals.silence(8, from: end + RepSignals.dt) {
            _ = c.feed(s)
            if overAt == nil, SetEnd.due(c, now: s.t) { overAt = s.t }
        }
        XCTAssertNotNil(overAt)
        // Four seconds from when the last movement was over, which is a little before `end`.
        XCTAssertEqual((overAt ?? 0) - end, 4, accuracy: 1.0)
        assertCount(c.count, about: 10)
    }

    func testASetWithoutARhythmNeverEndsByItself() {
        var c = RepCounter()
        for s in RepSignals.reps(2) + RepSignals.silence(10, from: 10) {
            _ = c.feed(s)
            XCTAssertFalse(SetEnd.due(c, now: s.t))
        }
    }

    func testTheSetIsNotOverWhileTheWristMoves() {
        var c = RepCounter()
        for s in RepSignals.reps(10, rest: 1.5) {
            _ = c.feed(s)
            XCTAssertFalse(SetEnd.due(c, now: s.t), "at \(s.t)")
        }
    }

    /* ---------- the parts ---------- */

    func testTheBandPassKeepsARepsTempoAndDropsTheRest() {
        func gain(_ hz: Double) -> Double {
            var f = BandPass(rate: 50, low: 0.05, high: 3)
            var peak = 0.0
            for i in 0..<40000 {
                let y = f.step(sin(2 * .pi * hz * Double(i) / 50))
                if i > 20000 { peak = max(peak, abs(y)) }
            }
            return peak
        }
        XCTAssertGreaterThan(gain(1.0), 0.9)
        XCTAssertGreaterThan(gain(0.15), 0.9, "a rep that takes seven seconds")
        XCTAssertLessThan(gain(0.005), 0.05)
        XCTAssertLessThan(gain(15), 0.1)
    }

    func testTheRollingMeanIsTheMeanOfItsWindow() {
        var m = RollingMean(size: 3)
        XCTAssertEqual(m.push(3), 3)
        XCTAssertEqual(m.push(6), 4.5)
        XCTAssertEqual(m.push(9), 6)
        XCTAssertEqual(m.push(12), 9)
    }
}
