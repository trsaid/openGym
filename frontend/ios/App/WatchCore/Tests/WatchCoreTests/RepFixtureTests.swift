import XCTest
@testable import WatchCore

/// The counter on recorded sets (Fixtures/traces): every set a real wrist did, played back.
final class RepFixtureTests: XCTestCase {

    static func recorded() -> [(file: String, trace: SetTrace)] {
        guard let dir = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/traces"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted().flatMap { name -> [(String, SetTrace)] in
            let data = (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data()
            return TraceBundle.traces(in: data).map { (name, $0) }
        }
    }

    func testEveryRecordedSetReadsAndPlaysBack() {
        let sets = RepFixtureTests.recorded()
        var exact = 0, close = 0
        for (file, t) in sets {
            XCTAssertEqual(t.samples.count, t.n, "\(file): \(t.name) has not the readings it says")
            XCTAssertGreaterThan(t.rate, 0, file)
            let got = TraceReplay.count(t)
            if got == t.reps { exact += 1 }
            if abs(got - t.reps) <= 1 { close += 1 }
            // What the general settings make of each set, in the test log: this is what a
            // profile for the exercise has to beat.
            print("recorded set: \(t.name) \(t.side ?? "") logged \(t.reps), counted then \(t.counted.map(String.init) ?? "-"), now \(got)\(t.edited ? " (looked at)" : "")")
        }
        if !sets.isEmpty { print("recorded sets: \(sets.count), exact \(exact), within one \(close)") }
    }
}
