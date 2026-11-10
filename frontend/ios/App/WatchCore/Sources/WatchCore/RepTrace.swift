import Foundation

/*
 * A set as the wrist felt it, kept with what was logged for it: the readings of the motion
 * sensors from a little before the first rep to the tick, the reps the counter showed and the
 * reps the lifter logged. The logged reps are the truth the counter is measured against, so
 * every ticked set is a lesson (docs/dev/REP_COUNTING.md): the profiles are learned by playing
 * these back, and the ones in Tests/WatchCoreTests/Fixtures/traces are played back by CI.
 *
 * Nothing here leaves the watch by itself. The traces stay in the watch app's own folder, the
 * newest few per exercise, until they are exported on purpose (Settings → Apple Watch).
 */

/// The counter as the workout uses it: it listens all the time a set with reps is up or coming
/// up, keeps the last readings, and hands the set over when it is ticked.
struct RepTracker: Equatable {
    /// How much is kept at most, and how much before the first rep goes into a trace (seconds).
    static let keepSec: Double = 150
    static let leadSec: Double = 8
    /// What is kept of a set the counter found no rhythm in: the end of it.
    static let blindSec: Double = 60

    private(set) var counter: RepCounter
    private(set) var samples: [MotionSample] = []
    private let settings: RepSettings
    private let rate: Double

    init(settings: RepSettings = .general, rate: Double = 50) {
        self.settings = settings
        self.rate = rate
        counter = RepCounter(settings: settings, rate: rate)
    }

    /// The count to show on the reps tile: none until a rhythm was found.
    var shown: Int? { counter.count > 0 ? counter.count : nil }

    /// One reading in. Says whether the count on the tile changed.
    mutating func feed(_ s: MotionSample) -> Bool {
        let before = counter.count
        _ = counter.feed(s)
        samples.append(s)
        // Dropped in chunks, so the array is not shifted on every reading.
        let cap = Int(Self.keepSec * rate)
        if samples.count > cap + Int(rate) * 10 { samples.removeFirst(samples.count - cap) }
        return counter.count != before
    }

    /// The set was ticked: its readings, and a fresh counter for the next one.
    mutating func cut() -> [MotionSample] {
        let from: Double
        if let first = counter.burstFrom, counter.count > 0 {
            from = first - Self.leadSec
        } else {
            from = (samples.last?.t ?? 0) - Self.blindSec
        }
        let out = samples.filter { $0.t >= from }
        samples = []
        counter = RepCounter(settings: settings, rate: rate)
        return out
    }
}

/// One recorded set. `data` holds the readings (TraceCodec); the rest says what they are.
struct SetTrace: Codable, Equatable {
    var v: Int = 1
    /// The exercise (the workout's entry id and name), and the side of a per-side set.
    var exId: String
    var name: String
    var side: String?
    /// What was logged, and what the counter showed when it was (none: it found no rhythm).
    var reps: Int
    var counted: Int?
    /// The lifter changed the reps by hand before the tick: they looked, so `reps` is certain.
    /// A set ticked without a look may carry the counter's own mistake.
    var edited: Bool
    /// The set ended by itself (SetEnd), not by a tap.
    var auto: Bool?
    var w: Double?
    var unit: String?
    /// When it was ticked (ms since 1970).
    var at: Double
    /// The wrist the watch is on and the side its crown is on ("left" / "right").
    var wrist: String?
    var crown: String?
    var rate: Double
    var n: Int
    var data: Data

    var samples: [MotionSample] { TraceCodec.unpack(data, rate: rate) }

    /// The file it is kept in: sorts by time, and says which exercise without opening it.
    var fileName: String { "\(Int(at))-\(TraceShelf.safe(exId)).json" }
}

/// The readings packed small: nine 16-bit numbers a reading, little-endian, about 55 kB a minute
/// at 50 a second. The time is not stored: the readings are evenly spaced (`rate`).
enum TraceCodec {
    /// One step of each kind of value: acceleration (to ±8 g), the gravity vector, rotation (to ±32 rad/s).
    static let accelStep: Double = 1.0 / 4096
    static let gravityStep: Double = 1.0 / 16384
    static let rotationStep: Double = 1.0 / 1024
    static let width = 9

    static func pack(_ samples: [MotionSample]) -> Data {
        var out = Data(capacity: samples.count * width * 2)
        func put(_ v: Double, _ step: Double) {
            let q = Int16(max(-32767, min(32767, (v / step).rounded())))
            let u = UInt16(bitPattern: q)
            out.append(UInt8(u & 0xff))
            out.append(UInt8(u >> 8))
        }
        for s in samples {
            put(s.ax, accelStep); put(s.ay, accelStep); put(s.az, accelStep)
            put(s.gx, gravityStep); put(s.gy, gravityStep); put(s.gz, gravityStep)
            put(s.rx, rotationStep); put(s.ry, rotationStep); put(s.rz, rotationStep)
        }
        return out
    }

    static func unpack(_ data: Data, rate: Double) -> [MotionSample] {
        let bytes = [UInt8](data)
        let n = bytes.count / (width * 2)
        guard rate > 0, n > 0 else { return [] }
        func get(_ i: Int, _ k: Int, _ step: Double) -> Double {
            let at = (i * width + k) * 2
            return Double(Int16(bitPattern: UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8)) * step
        }
        return (0..<n).map { i in
            MotionSample(t: Double(i) / rate,
                         ax: get(i, 0, accelStep), ay: get(i, 1, accelStep), az: get(i, 2, accelStep),
                         gx: get(i, 3, gravityStep), gy: get(i, 4, gravityStep), gz: get(i, 5, gravityStep),
                         rx: get(i, 6, rotationStep), ry: get(i, 7, rotationStep), rz: get(i, 8, rotationStep))
        }
    }
}

/// Which traces the watch keeps: the newest `perExercise` of each exercise, `total` at most.
enum TraceShelf {
    static let perExercise = 20
    static let total = 400

    static func safe(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    /// The exercise a trace file is of ("<ms>-<exercise>.json"), or nil for another file.
    static func exercise(ofFile name: String) -> (at: Double, exId: String)? {
        guard name.hasSuffix(".json"), let dash = name.firstIndex(of: "-"), let at = Double(name[..<dash]) else { return nil }
        return (at, String(name[name.index(after: dash)...].dropLast(5)))
    }

    /// The files to delete, given all the files there are.
    static func toDrop(_ files: [String], perExercise: Int = perExercise, total: Int = total) -> [String] {
        let known = files.compactMap { f in exercise(ofFile: f).map { (file: f, at: $0.at, exId: $0.exId) } }
            .sorted { $0.at > $1.at }
        var seen: [String: Int] = [:]
        var kept = 0
        var drop: [String] = []
        for f in known {
            let n = seen[f.exId, default: 0]
            if n >= perExercise || kept >= total { drop.append(f.file); continue }
            seen[f.exId] = n + 1
            kept += 1
        }
        return drop
    }
}

/// What a recorded set says about the counter: played back, how far its count is from the truth.
enum TraceReplay {
    static func count(_ trace: SetTrace, settings: RepSettings = .general) -> Int {
        var c = RepCounter(settings: settings, rate: trace.rate)
        for s in trace.samples { _ = c.feed(s) }
        return c.count
    }
}
