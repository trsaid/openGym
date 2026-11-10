import Foundation

/*
 * Counting reps from the wrist's motion, as pure logic: the watch app feeds it the readings of
 * its motion sensors (Watch/MotionSampler.swift) and shows the count on the set's reps tile.
 * Tested with `swift test` on made-up signals and on recorded sets (Tests/WatchCoreTests), no
 * watch needed. Design: docs/dev/REP_COUNTING.md.
 *
 * It started from RepCounter by Devesh Aggarwal (MIT, see NOTICE.md): the band-pass, the rhythm
 * that has to show before anything is counted, the impacts that are ignored. What a rep is, is
 * different here, because RepCounter's answer (one burst of movement between two rests) counts a
 * lift done at a steady tempo twice or not at all: played against lifts worked out from the
 * laws of motion (RepSignals.lift), ten bench presses came out as nineteen.
 *
 *   one rep = one swing of the acceleration along the line the wrist moves on
 *       Going up and coming down, the wrist is pushed one way, then the other, then the other
 *       again and back: along its line of travel the acceleration swings once per rep, whether
 *       the reps run into each other or stop at the top, and however slow the way down is. The
 *       counter follows that line (the direction that holds most of the movement, found as it
 *       goes, so it does not matter how the watch sits on the wrist) and counts each time the
 *       signal goes out past a threshold on the side a rep starts on and then past its mirror
 *       on the other side: the turn at the far end of the rep. The start spike and the stop
 *       spike of one rep are on the same swing: one count. The way down may be so slow that
 *       it does not show at all; the turn still does.
 *   what to listen to
 *       The acceleration, by default. For push-ups, pull-ups and dips the hand does not move at
 *       all and the forearm's tilt is the only thing that changes: `RepSettings.tilt` is where
 *       a profile learned for one exercise says so.
 *   a rhythm first
 *       Nothing is counted until `confirmReps` swings arrive at a steady tempo; then the count
 *       jumps to that many and goes on live. Once the tempo is known, a swing that comes much
 *       too soon after the last one is a wobble, not a rep.
 *   the workout says where a set starts and ends
 *       RepCounter ends a set after a few quiet seconds. Here the set is the one the workout
 *       shows, and it ends when it is ticked (SessionStore), so there is no set-end guess in the
 *       counter. A long pause only means the next steady rhythm starts a new count (`staleSec`):
 *       what came before was the walk to the bar, not the set.
 */

/// One reading of the wrist, in the watch's own axes (CoreMotion's device motion).
struct MotionSample: Equatable {
    /// Seconds on the sensor's own clock (it only ever goes forward).
    var t: Double
    /// Acceleration without gravity, in g.
    var ax: Double = 0, ay: Double = 0, az: Double = 0
    /// Where down is, as a unit vector: how the forearm is held.
    var gx: Double = 0, gy: Double = 0, gz: Double = -1
    /// Rotation rate, in radians per second.
    var rx: Double = 0, ry: Double = 0, rz: Double = 0
}

/// What the counter listens to and how. The defaults are the general settings every exercise
/// starts with; a profile learned for one exercise replaces them (docs/dev/REP_COUNTING.md).
struct RepSettings: Equatable {
    /// The band a rep's motion lives in, in Hz: slower is drift, faster is shaking and impacts.
    var lowCut: Double = 0.05
    var highCut: Double = 3.0
    /// How much the acceleration and the forearm's tilt count in what is followed.
    var accel: Double = 1
    var tilt: Double = 0
    /// How long the line of travel remembers (seconds): it follows a grip that changes, slowly.
    var axisSec: Double = 20.0
    /// A swing counts when the signal passes this share of its recent size on one side, after
    /// having passed the same share on the other.
    var fireFrac: Double = 0.25
    /// Below this nothing is a swing, whatever came before (g).
    var noiseFloor: Double = 0.012
    /// How fast the memory of the signal's recent size fades (seconds to half).
    var refHalfLife: Double = 6.0
    /// Nothing counts in the first moments after the counter starts (the filters settle).
    var warmup: Double = 0.5
    /// A weight put down or plates clinking: a spike this hard (g), and nothing counts for
    /// `impactHold` seconds.
    var impactG: Double = 2.0
    var impactHold: Double = 0.3
    /// How many steady swings it takes before the count starts.
    var confirmReps: Int = 3
    /// A rep's tempo while the rhythm is being found: seconds from one rep to the next, and how
    /// far one gap may differ from the one before.
    var minPeriod: Double = 0.5
    var maxPeriod: Double = 10.0
    var ratioLo: Double = 0.5
    var ratioHi: Double = 2.0
    /// With the tempo known, a swing sooner than this share of it after the last is a wobble.
    var refractory: Double = 0.5
    /// A pause this long between two reps: the next steady rhythm starts a new count.
    var staleSec: Double = 20.0
    /// The wrist is moving above this share of the recent movement energy and still below that
    /// one, averaged over `stillWindow` seconds (for a set that ends by itself, SetEnd).
    var activeFrac: Double = 0.50
    var restFrac: Double = 0.30
    var stillWindow: Double = 0.4

    static let general = RepSettings()
}

/// A second-order filter (RBJ cookbook, Butterworth Q), one sample at a time.
struct Biquad: Equatable {
    private let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1 = 0.0, z2 = 0.0

    mutating func step(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func lowPass(rate: Double, cutoff: Double) -> Biquad { make(rate, cutoff, high: false) }
    static func highPass(rate: Double, cutoff: Double) -> Biquad { make(rate, cutoff, high: true) }

    private static func make(_ rate: Double, _ cutoff: Double, high: Bool) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / rate
        let c = cos(w0), alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))
        let a0 = 1 + alpha
        let k = high ? (1 + c) : (1 - c)
        return Biquad(b0: k / 2 / a0, b1: (high ? -k : k) / a0, b2: k / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
}

/// The band-pass of one axis: slow drift out, then shaking out.
struct BandPass: Equatable {
    private var hp: Biquad, lp: Biquad
    init(rate: Double, low: Double, high: Double) {
        hp = .highPass(rate: rate, cutoff: low)
        lp = .lowPass(rate: rate, cutoff: high)
    }
    mutating func step(_ x: Double) -> Double { lp.step(hp.step(x)) }
}

/// The mean of the last `size` values, kept as a running sum.
struct RollingMean: Equatable {
    private var ring: [Double]
    private var at = 0, filled = 0, sum = 0.0
    init(size: Int) { ring = Array(repeating: 0, count: max(1, size)) }
    mutating func push(_ v: Double) -> Double {
        if filled == ring.count { sum -= ring[at] } else { filled += 1 }
        ring[at] = v
        sum += v
        at = (at + 1) % ring.count
        return max(0, sum) / Double(filled)
    }
}

struct RepCounter: Equatable {
    /// The readings that are followed: three of acceleration, three of tilt.
    static let width = 6

    let settings: RepSettings
    let rate: Double

    /// The reps counted so far: 0 until a rhythm shows.
    private(set) var count = 0
    /// A steady rhythm is there and reps are counted live.
    private(set) var locked = false
    /// The wrist is moving right now.
    private(set) var moving = false
    /// When the last rep was counted, and when the wrist last came to rest (sensor seconds).
    private(set) var lastRepAt: Double?
    private(set) var stillSince: Double?
    /// When the first rep of the rhythm that is counted now was seen: where the set begins.
    private(set) var burstFrom: Double?
    /// The tempo of the reps counted lately (seconds from one to the next), once known.
    var period: Double? {
        guard !gaps.isEmpty else { return nil }
        return gaps.sorted()[gaps.count / 2]
    }

    private var bands: [BandPass]
    /// How the followed readings move together lately (a 6 by 6 covariance, row by row), and
    /// the direction that holds most of it: the line of travel.
    private var cov: [Double]
    private var axis: [Double]
    private let covKeep: Double
    private var ref = 0.0
    private let refDecay: Double
    /// The side of the signal a rep starts on (+1 or -1), whether that side was just seen, and
    /// when the signal was last past the threshold at all.
    private var outer: Double?
    private var armed = false
    private var lastOut: Double?
    private var energy: RollingMean
    private var energyRef = 0.0
    private var startedAt: Double?
    /// Where the filters start from: the first reading of gravity (from zero it would ring
    /// through them for seconds), and zero for the acceleration, which rests at zero.
    private var origin: [Double] = []
    private var impactUntil = -Double.infinity
    private var lastOnset: Double?
    private var streak = 0
    private var pending: [Double] = []
    private var lastGap: Double?
    private var gaps: [Double] = []

    init(settings: RepSettings = .general, rate: Double = 50) {
        self.settings = settings
        self.rate = rate
        bands = (0..<Self.width).map { _ in BandPass(rate: rate, low: settings.lowCut, high: settings.highCut) }
        cov = Array(repeating: 0, count: Self.width * Self.width)
        axis = Array(repeating: 0, count: Self.width)
        covKeep = exp(-(1 / rate) / settings.axisSec)
        refDecay = pow(0.5, (1 / rate) / settings.refHalfLife)
        energy = RollingMean(size: Int(settings.stillWindow * rate))
    }

    /// Takes one reading and says how many reps it added to the count: 0 most of the time, 1
    /// for a rep, `confirmReps` at once when the rhythm is found. A new rhythm after a long pause
    /// starts the count again, so `count` is what to show, not a sum of what this returned.
    mutating func feed(_ s: MotionSample) -> Int {
        let t = s.t
        if startedAt == nil { startedAt = t }
        let c = settings
        let n = Self.width

        // What is followed, in the band of a rep.
        let raw = [s.ax, s.ay, s.az, s.gx, s.gy, s.gz]
        if origin.isEmpty { origin = [0, 0, 0, s.gx, s.gy, s.gz] }
        var v = Array(repeating: 0.0, count: n)
        var e = 0.0
        for i in 0..<n {
            let weight = i < 3 ? c.accel : c.tilt
            guard weight != 0 else { continue }
            v[i] = weight * bands[i].step(raw[i] - origin[i])
            e += v[i] * v[i]
        }

        // The line of travel: the direction most of the movement is along, followed by one
        // step of power iteration a reading. It turns slowly and never flips, so the signal
        // along it stays one continuous swing.
        var next = Array(repeating: 0.0, count: n)
        var size = 0.0
        for i in 0..<n {
            var sum = 0.0
            for j in 0..<n {
                let k = i * n + j
                cov[k] = covKeep * cov[k] + (1 - covKeep) * v[i] * v[j]
                sum += cov[k] * axis[j]
            }
            next[i] = sum
            size += sum * sum
        }
        if size > 1e-24 {
            let len = size.squareRoot()
            for i in 0..<n { axis[i] = next[i] / len }
        } else if e > 1e-12 {
            // Nothing to go by yet: start along the first movement there is.
            let len = e.squareRoot()
            for i in 0..<n { axis[i] = v[i] / len }
        }
        var p = 0.0
        for i in 0..<n { p += axis[i] * v[i] }

        // The threshold follows the lift: large for an arm that swings, small for the faint
        // shaking a squat sends to the wrist.
        ref = max(abs(p), ref * refDecay)
        let level = max(c.noiseFloor, c.fireFrac * ref)

        // Whether the wrist moves at all, for a set that ends by itself.
        let env = energy.push(e).squareRoot()
        energyRef = max(env, energyRef * refDecay)
        if !moving {
            if env > max(c.noiseFloor, c.activeFrac * energyRef) { moving = true }
        } else if env < max(c.noiseFloor * 0.6, c.restFrac * energyRef) {
            moving = false
            stillSince = t
        }

        // Impacts: a hard spike is not a rep, and neither is what rings after it.
        let hit = (s.ax * s.ax + s.ay * s.ay + s.az * s.az).squareRoot()
        if hit >= c.impactG { impactUntil = t + c.impactHold }

        // One swing: out past the threshold on the side the rep starts on, then past its mirror
        // on the other. Which side a rep starts on is not known beforehand (the line of travel
        // has no up or down): it is the side of the first excursion after a long quiet.
        if abs(p) > level {
            let side: Double = p > 0 ? 1 : -1
            if let last = lastOut, t - last > c.maxPeriod { outer = nil; armed = false }
            lastOut = t
            // Sensor noise on a still wrist gets past the threshold now and then: only a wrist
            // that really moves says where a rep starts.
            if outer == nil {
                guard moving else { return 0 }
                outer = side
            }
            if side == outer {
                armed = true
            } else if armed {
                armed = false
                if t >= impactUntil && t - (startedAt ?? t) >= c.warmup { return swing(at: t) }
            }
        }
        return 0
    }

    /// One swing of the signal. Counted at once when the rhythm is there; otherwise kept until
    /// `confirmReps` of them came at a steady tempo.
    private mutating func swing(at t: Double) -> Int {
        let c = settings
        let gap = lastOnset.map { t - $0 }

        if locked {
            if let g = gap, g > c.staleSec {
                // A long pause: what comes now has to show a rhythm of its own. The count on
                // the screen stays until it does.
                locked = false
                gaps = []
                lastOnset = t
                restartRhythm(at: t)
                return 0
            }
            // Much too soon after the last rep: a wobble at the top, the bar settling.
            if let g = gap, let tempo = period, g < c.refractory * tempo { return 0 }
            lastOnset = t
            if let g = gap { gaps.append(g); if gaps.count > 5 { gaps.removeFirst() } }
            count += 1
            lastRepAt = t
            return 1
        }

        if let g = gap, g < c.minPeriod { return 0 }
        lastOnset = t
        if let g = gap, g <= c.maxPeriod {
            let steady = lastGap.map { g / $0 >= c.ratioLo && g / $0 <= c.ratioHi } ?? true
            if steady {
                streak += 1
                pending.append(t)
                gaps.append(g)
                lastGap = g
            } else {
                restartRhythm(at: t)
            }
        } else {
            restartRhythm(at: t)
        }

        guard streak >= c.confirmReps else { return 0 }
        // The rhythm is there: the count starts at the swings that made it.
        locked = true
        count = pending.count
        burstFrom = pending.first
        lastRepAt = t
        pending = []
        return count
    }

    private mutating func restartRhythm(at t: Double) {
        streak = 1
        pending = [t]
        lastGap = nil
        gaps = []
    }
}

/*
 * A set that ends by itself (the phone's Settings → Apple Watch, "End the set by itself"): once
 * the counter has a rhythm and the wrist has been still for a while, the set is ticked with the
 * count. Never without a rhythm: a set the counter did not follow is ticked by hand.
 */
enum SetEnd {
    /// Still for this long, and for one and a half reps at the set's own tempo: a slow lowering
    /// or a breath between two heavy reps is not the end.
    static let quietSec: Double = 4
    static let tempoShare: Double = 1.5

    static func quiet(for c: RepCounter, atLeast: Double = quietSec) -> Double {
        max(atLeast, tempoShare * (c.period ?? 0))
    }

    /// Whether the set is over now (sensor seconds).
    static func due(_ c: RepCounter, now t: Double, quiet atLeast: Double = quietSec) -> Bool {
        guard c.locked, c.count > 0, !c.moving, let still = c.stillSince, let last = c.lastRepAt else { return false }
        return t - max(still, last) >= quiet(for: c, atLeast: atLeast)
    }
}
