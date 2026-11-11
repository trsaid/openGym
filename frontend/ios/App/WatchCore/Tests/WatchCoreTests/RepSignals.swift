import Foundation
@testable import WatchCore

/// Made-up wrist signals for the rep counter's tests (after RepCounter's SignalGenerators).
enum RepSignals {
    static let rate: Double = 50
    static var dt: Double { 1 / rate }

    /// The same numbers every run.
    struct Dice {
        var state: UInt64
        init(seed: UInt64) { state = seed | 1 }
        mutating func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gauss() -> Double {
            let a = max(unit(), 1e-12), b = unit()
            return (-2 * log(a)).squareRoot() * cos(2 * .pi * b)
        }
    }

    /// A reading with `v` g along `axis` (a direction in the watch's axes, any length).
    static func sample(_ t: Double, _ v: Double, axis: (Double, Double, Double) = (0, 0, 1)) -> MotionSample {
        let len = (axis.0 * axis.0 + axis.1 * axis.1 + axis.2 * axis.2).squareRoot()
        return MotionSample(t: t, ax: v * axis.0 / len, ay: v * axis.1 / len, az: v * axis.2 / len)
    }

    static func silence(_ seconds: Double, from start: Double = 0) -> [MotionSample] {
        (0..<Int(seconds * rate)).map { sample(start + Double($0) * dt, 0) }
    }

    /// A wrist held still: sensor noise on every axis.
    static func noise(sigma: Double, _ seconds: Double, seed: UInt64 = 42) -> [MotionSample] {
        var dice = Dice(seed: seed)
        return (0..<Int(seconds * rate)).map {
            MotionSample(t: Double($0) * dt, ax: sigma * dice.gauss(), ay: sigma * dice.gauss(), az: sigma * dice.gauss())
        }
    }

    /// `reps` reps as a wrist feels them: rest, a burst of movement, rest. Each burst is
    /// `cycles` cycles of a sine at `moveHz`, so it holds the start spike and the stop spike of
    /// a real rep: counting spikes would count about twice as many.
    static func reps(_ reps: Int, moveHz: Double = 2.5, cycles: Double = 1.5, amplitude: Double = 0.4,
                     amplitudeEnd: Double? = nil, rest: Double = 0.6, lead: Double = 0.8, noise sigma: Double = 0,
                     axis: (Double, Double, Double) = (0, 0, 1), from start: Double = 0, seed: UInt64 = 42) -> [MotionSample] {
        var dice = Dice(seed: seed)
        var out: [MotionSample] = []
        func segment(_ seconds: Double, _ amp: Double) {
            for i in 0..<Int(seconds * rate) {
                let v = amp * sin(2 * .pi * moveHz * Double(i) * dt) + (sigma > 0 ? sigma * dice.gauss() : 0)
                out.append(sample(start + Double(out.count) * dt, v, axis: axis))
            }
        }
        segment(lead, 0)
        for r in 0..<reps {
            let part = reps > 1 ? Double(r) / Double(reps - 1) : 0
            segment(cycles / moveHz, amplitudeEnd.map { amplitude + ($0 - amplitude) * part } ?? amplitude)
            segment(rest, 0)
        }
        return out
    }

    /// The same reps with a hand that does not move (a push-up, a dip): no acceleration, only
    /// the forearm tilting by `degrees` and back.
    static func tiltReps(_ reps: Int, degrees: Double = 12, moveHz: Double = 1.2, rest: Double = 0.7) -> [MotionSample] {
        var out: [MotionSample] = []
        func segment(_ seconds: Double, moving: Bool) {
            for i in 0..<Int(seconds * rate) {
                let a = moving ? degrees * .pi / 180 * sin(2 * .pi * moveHz * Double(i) * dt) : 0
                out.append(MotionSample(t: Double(out.count) * dt, gx: sin(a), gy: 0, gz: -cos(a)))
            }
        }
        segment(0.8, moving: false)
        for _ in 0..<reps {
            segment(1 / moveHz, moving: true)
            segment(rest, moving: false)
        }
        return out
    }

    /// Reps as the laws of motion make them: the wrist travels `travel` metres up in `up`
    /// seconds and back down in `down`, smoothly (a minimum-jerk stroke), with a pause at the top
    /// and at the bottom. The acceleration is what such a stroke takes, so a slow lowering is
    /// far fainter than a fast push, and reps done without a pause run into each other.
    static func lift(_ reps: Int, up: Double = 1.0, down: Double = 1.5, top: Double = 0, bottom: Double = 0,
                     travel: Double = 0.45, lead: Double = 1.0, tail: Double = 0, noise sigma: Double = 0.004, jitter: Double = 0,
                     axis: (Double, Double, Double) = (0, 0, 1), from start: Double = 0, seed: UInt64 = 7) -> [MotionSample] {
        var dice = Dice(seed: seed)
        var out: [MotionSample] = []
        func put(_ g: Double) {
            var s = sample(start + Double(out.count) * dt, g, axis: axis)
            if sigma > 0 { s.ax += sigma * dice.gauss(); s.ay += sigma * dice.gauss(); s.az += sigma * dice.gauss() }
            out.append(s)
        }
        func hold(_ seconds: Double) { for _ in 0..<Int(seconds * rate) { put(0) } }
        func stroke(_ seconds: Double, _ metres: Double) {
            let n = Int(seconds * rate)
            for i in 0..<n {
                let x = Double(i) / Double(n)
                put(metres / (seconds * seconds) * (60 * x - 180 * x * x + 120 * x * x * x) / 9.81)
            }
        }
        hold(lead)
        for _ in 0..<reps {
            // No two reps are the same: each is a little faster or slower, shorter or longer.
            func vary(_ v: Double) -> Double { jitter > 0 ? v * (1 + jitter * (2 * dice.unit() - 1)) : v }
            let reach = vary(travel)
            stroke(vary(up), reach); hold(vary(top))
            stroke(vary(down), -reach); hold(vary(bottom))
        }
        hold(tail)
        return out
    }

    static func count(_ samples: [MotionSample], settings: RepSettings = .general) -> Int {
        var c = RepCounter(settings: settings, rate: rate)
        for s in samples { _ = c.feed(s) }
        return c.count
    }
}
