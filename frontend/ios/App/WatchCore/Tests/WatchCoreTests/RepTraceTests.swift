import XCTest
@testable import WatchCore

/// A set as it is recorded, kept and played back.
final class RepTraceTests: XCTestCase {

    func trace(_ samples: [MotionSample], reps: Int, counted: Int? = nil, exId: String = "0025", at: Double = 1_700_000_000_000) -> SetTrace {
        SetTrace(exId: exId, name: "Bench Press", side: nil, reps: reps, counted: counted, edited: false, auto: nil,
                 w: 60, unit: "kg", at: at, wrist: "left", crown: "right", rate: 50, n: samples.count, data: TraceCodec.pack(samples))
    }

    func testReadingsComeBackWithinOneStep() {
        let s = MotionSample(t: 0, ax: 0.1234, ay: -1.5, az: 7.9, gx: 0.6, gy: -0.64, gz: 0.48, rx: 3.25, ry: -12.5, rz: 0.001)
        let back = TraceCodec.unpack(TraceCodec.pack([s, s]), rate: 50)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[1].t, 0.02, accuracy: 1e-9)
        XCTAssertEqual(back[0].ax, s.ax, accuracy: TraceCodec.accelStep)
        XCTAssertEqual(back[0].ay, s.ay, accuracy: TraceCodec.accelStep)
        XCTAssertEqual(back[0].az, s.az, accuracy: TraceCodec.accelStep)
        XCTAssertEqual(back[0].gy, s.gy, accuracy: TraceCodec.gravityStep)
        XCTAssertEqual(back[0].ry, s.ry, accuracy: TraceCodec.rotationStep)
    }

    func testAReadingOffTheScaleIsClippedNotWrapped() {
        let back = TraceCodec.unpack(TraceCodec.pack([MotionSample(t: 0, ax: 40, ay: -40)]), rate: 50)
        XCTAssertEqual(back[0].ax, 8, accuracy: 0.01)
        XCTAssertEqual(back[0].ay, -8, accuracy: 0.01)
    }

    func testAMinuteIsAboutFiftyFiveKilobytes() {
        XCTAssertEqual(TraceCodec.pack(RepSignals.silence(60)).count, 54_000)
    }

    func testATraceSurvivesJSONAndCountsTheSameAfterwards() throws {
        let samples = RepSignals.lift(10)
        let t = trace(samples, reps: 10, counted: RepSignals.count(samples))
        let back = try JSONDecoder().decode(SetTrace.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
        XCTAssertEqual(TraceReplay.count(back), t.counted)
        XCTAssertEqual(t.fileName, "1700000000000-0025.json")
    }

    func testATraceFromANewerWatchStillReads() throws {
        // A field this build does not know, and the optional ones left out.
        let json = #"{"v":2,"exId":"0025","name":"Bench Press","reps":8,"edited":true,"at":1,"rate":50,"n":0,"data":"","later":"x"}"#
        let t = try JSONDecoder().decode(SetTrace.self, from: Data(json.utf8))
        XCTAssertEqual(t.reps, 8)
        XCTAssertNil(t.counted)
        XCTAssertEqual(t.samples.count, 0)
    }

    /* ---------- the tracker ---------- */

    func testTheTileShowsNothingUntilTheRhythmThenTheCount() {
        var tr = RepTracker()
        XCTAssertNil(tr.shown)
        var changes = 0
        for s in RepSignals.lift(8) { if tr.feed(s) { changes += 1 } }
        XCTAssertEqual(tr.shown, 8)
        XCTAssertEqual(changes, 6, "one change for the jump to three, then one a rep")
    }

    func testATickedSetIsCutFromALittleBeforeItsFirstRep() {
        var tr = RepTracker()
        // 60 s of rest, then the set.
        for s in RepSignals.silence(60) + RepSignals.lift(8, lead: 0, from: 60) { _ = tr.feed(s) }
        XCTAssertEqual(tr.shown, 8)
        let cut = tr.cut()
        // The first rep turns at its top one second in; the trace starts `leadSec` before that.
        XCTAssertEqual(cut.first?.t ?? 0, 61 - RepTracker.leadSec, accuracy: 0.6)
        XCTAssertEqual(RepSignals.count(cut), 8, "what is kept counts like what was felt")
        XCTAssertNil(tr.shown, "the next set starts at nothing")
        XCTAssertTrue(tr.samples.isEmpty)
    }

    func testASetWithoutARhythmKeepsItsLastMinute() {
        var tr = RepTracker()
        for s in RepSignals.noise(sigma: 0.01, 100) { _ = tr.feed(s) }
        let cut = tr.cut()
        XCTAssertEqual(Double(cut.count) / 50, RepTracker.blindSec, accuracy: 1)
    }

    func testTheTrackerForgetsWhatIsOlderThanItKeeps() {
        var tr = RepTracker()
        for s in RepSignals.silence(400) { _ = tr.feed(s) }
        XCTAssertLessThanOrEqual(Double(tr.samples.count) / 50, RepTracker.keepSec + 11)
    }

    /* ---------- which traces are kept ---------- */

    func testTheNewestTwentyOfEachExerciseAreKept() {
        var files = (0..<25).map { "\(1000 + $0)-0025.json" } + (0..<3).map { "\(2000 + $0)-0426.json" }
        files.append("notes.txt")
        let drop = TraceShelf.toDrop(files)
        XCTAssertEqual(Set(drop), Set((0..<5).map { "\(1000 + $0)-0025.json" }))
    }

    func testTheShelfHasAnEnd() {
        let files = (0..<30).map { "\($0)-ex\($0).json" }
        XCTAssertEqual(TraceShelf.toDrop(files, total: 10).count, 20)
        XCTAssertFalse(TraceShelf.toDrop(files, total: 10).contains("29-ex29.json"))
    }

    func testAnExerciseIdBecomesAFileName() {
        XCTAssertEqual(TraceShelf.safe("custom/a b:1"), "custom_a_b_1")
        XCTAssertEqual(TraceShelf.exercise(ofFile: "1700000000000-custom_a_b_1.json")?.exId, "custom_a_b_1")
        XCTAssertNil(TraceShelf.exercise(ofFile: "readme.md"))
    }
}
