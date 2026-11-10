import CoreMotion
import Foundation
import WatchConnectivity
import WatchKit

/*
 * The wrist's motion for the rep counter (WatchCore RepCounter and RepTrace, design in
 * docs/dev/REP_COUNTING.md): CoreMotion's device motion, fifty readings a second, fed to the
 * counter on a queue of its own. The main thread hears of it only when there is something to
 * show: the count changed, or the set looks over.
 *
 * It runs only while a set with reps is up or coming up (SessionStore.syncCounting), inside the
 * workout session that keeps the app running with the wrist down. Nothing is read outside a
 * workout, and nothing with rep counting switched off on the phone.
 */

/// What the counter has of a set when it is ticked.
struct RepCut {
    var samples: [MotionSample]
    /// The count it showed (none: it found no rhythm).
    var counted: Int?
    /// How long ago the last rep was, in seconds.
    var sinceLastRep: Double?
}

final class RepSensor {
    static let rate: Double = 50

    /// Both on the main queue. `token` says which set the news is of: SessionStore drops news of
    /// a set that is no longer the one up (`token` below has moved on).
    var onCount: ((_ count: Int, _ token: Int) -> Void)?
    var onQuiet: ((_ token: Int) -> Void)?

    /// The set that is listened for now, as a number that goes up with every new one. Main queue.
    private(set) var token = 0
    private(set) var listening = false

    private let manager = CMMotionManager()
    private let readings = OperationQueue()
    /// The readings and the counter live on `work`. Starting and stopping the sensor has a queue
    /// to itself: the first start after launch can block for a second, which neither the main
    /// thread nor a tick waiting for the set's readings should sit out.
    private let work = DispatchQueue(label: "ch.opengym.reps")
    private let control = DispatchQueue(label: "ch.opengym.reps.control")

    // Only on `work`.
    private var tracker = RepTracker(rate: RepSensor.rate)
    private var live = 0
    private var endsSets = false
    private var quietTold = false

    init() {
        manager.deviceMotionUpdateInterval = 1 / RepSensor.rate
        readings.name = "ch.opengym.reps.readings"
        readings.maxConcurrentOperationCount = 1
        readings.underlyingQueue = work
    }

    /// Listens (it may already): `endsSets` is the phone's "End the set by itself".
    func start(endsSets: Bool) {
        work.async { self.endsSets = endsSets }
        guard !listening else { return }
        listening = true
        control.async { [weak self] in
            guard let self = self, self.manager.isDeviceMotionAvailable, !self.manager.isDeviceMotionActive else { return }
            self.manager.startDeviceMotionUpdates(to: self.readings) { [weak self] motion, _ in
                guard let self = self, let m = motion else { return }
                self.take(MotionSample(t: m.timestamp,
                                       ax: m.userAcceleration.x, ay: m.userAcceleration.y, az: m.userAcceleration.z,
                                       gx: m.gravity.x, gy: m.gravity.y, gz: m.gravity.z,
                                       rx: m.rotationRate.x, ry: m.rotationRate.y, rz: m.rotationRate.z))
            }
        }
    }

    func stop() {
        guard listening else { return }
        listening = false
        control.async { [weak self] in self?.manager.stopDeviceMotionUpdates() }
    }

    /// Another set is up: a fresh count. Returns the token its news will carry.
    @discardableResult func reset() -> Int {
        token += 1
        let now = token
        work.async {
            self.live = now
            self.quietTold = false
            self.tracker.reset()
        }
        return now
    }

    /// The set was ticked: its readings and its count, and a fresh counter for the next one.
    func cut() -> RepCut {
        token += 1
        let now = token
        return work.sync {
            let counted = tracker.shown, since = tracker.sinceLastRep
            live = now
            quietTold = false
            return RepCut(samples: tracker.cut(), counted: counted, sinceLastRep: since)
        }
    }

    private func take(_ s: MotionSample) {
        if tracker.feed(s) {
            // A rep after the set looked over: it was not, and it may look over again later.
            quietTold = false
            let n = tracker.shown ?? 0, of = live
            DispatchQueue.main.async { self.onCount?(n, of) }
        }
        if endsSets, !quietTold, SetEnd.due(tracker.counter, now: s.t) {
            quietTold = true
            let of = live
            DispatchQueue.main.async { self.onQuiet?(of) }
        }
    }
}

/*
 * The recorded sets (SetTrace) on the watch: one small JSON file each in the app's own folder,
 * the newest few per exercise (TraceShelf), and a copy of each sent to the paired iPhone, which
 * keeps them for the export in Settings → Apple Watch (WatchBridgePlugin). The watch keeps its
 * own, for the learning that plays them back (docs/dev/REP_COUNTING.md).
 */
enum TraceStore {
    private static let queue = DispatchQueue(label: "ch.opengym.traces", qos: .utility)
    private static let sentKey = "tracesSent"

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("traces")
    }

    private static func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { TraceShelf.exercise(ofFile: $0) != nil }
    }

    /// How many are kept, and how many of them the phone has: the hidden debug screen.
    static var summary: String {
        let all = files(), sent = Set(UserDefaults.standard.stringArray(forKey: sentKey) ?? [])
        return "\(all.count) kept, \(all.filter { sent.contains($0) }.count) on the phone"
    }

    /// Keeps one set: written, the oldest dropped, sent to the phone.
    static func keep(_ trace: SetTrace) {
        queue.async {
            guard let data = try? JSONEncoder().encode(trace) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent(trace.fileName), options: .atomic)
            for old in TraceShelf.toDrop(files()) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
            sendWaiting()
        }
    }

    /// Sends the phone what it does not have yet (a new set, or the ones kept while the link was
    /// not up). The system queues the files and delivers them when it can.
    static func sendWaiting() {
        queue.async {
            guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
            let all = files()
            // The list of what was sent only names files that are still there.
            let sent = Set(UserDefaults.standard.stringArray(forKey: sentKey) ?? []).intersection(all)
            UserDefaults.standard.set(Array(sent).sorted(), forKey: sentKey)
            let under = Set(WCSession.default.outstandingFileTransfers.compactMap { $0.file.metadata?["trace"] as? String })
            for name in all.sorted() where !sent.contains(name) && !under.contains(name) {
                WCSession.default.transferFile(dir.appendingPathComponent(name), metadata: ["trace": name])
            }
        }
    }

    /// A file reached the phone: not sent again.
    static func delivered(_ name: String) {
        queue.async {
            var sent = Set(UserDefaults.standard.stringArray(forKey: sentKey) ?? [])
            sent.insert(name)
            UserDefaults.standard.set(Array(sent).sorted(), forKey: sentKey)
        }
    }

    /// The wrist the watch is worn on and the side its crown is on, as the watch is set up.
    static var wrist: String { WKInterfaceDevice.current().wristLocation == .left ? "left" : "right" }
    static var crown: String { WKInterfaceDevice.current().crownOrientation == .left ? "left" : "right" }
}
