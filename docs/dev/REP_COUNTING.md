# Rep counting on the Apple Watch

The watch counts the reps of a set from the way the wrist moves and puts the number on the set's
reps tile. This note says what it does, where the code is, how a rep is told from everything else
a wrist does in a gym, and what is not known yet.

It is a first version on purpose. The counter was built and tested against made-up signals only
(lifts worked out from the laws of motion); how well it does on a real wrist is what the recorded
sets are for. Read "What is not known yet" before trusting a number.

## What the lifter sees

- A set with reps is up: the reps tile shows the set's target, as before. A few reps in, once the
  counter has found a rhythm, the tile turns to the accent colour and shows the count, which goes
  up with each rep. The wrist gets a light tap at each one.
- Done logs what the tile says. A tap on the tile still opens the reps on the crown: reps changed
  by hand stay as they are, the counter no longer touches that set.
- With "End the set by itself" on, a few quiet seconds after the last rep bring up a 3-2-1 with
  the count in it. It ticks the set at zero, or at once on a tap. Cancel, or another rep, keeps
  the set open. The rest that follows counts from the last rep, not from the tick.
- No rhythm found (a set of two reps, an exercise the wrist does not show): nothing changes, the
  set is ticked with Done like any other.

Settings → Apple Watch on the phone has the switches (`lib/watch-settings.js`):

| Setting | Default | The watch reads it as |
|---|---|---|
| Count reps on the watch | on | `settings.autoReps` |
| Tap the wrist at each rep | on | `settings.repHaptics` |
| End the set by itself | off | `settings.autoEnd` |

They travel in the snapshot's `settings` like the others. Nothing else in the watch protocol
changed: a counted set is ticked with the same `setDone` event as a set typed by hand.

## Where the code is

| File | What it holds |
|---|---|
| `WatchCore/Sources/WatchCore/RepCounter.swift` | The counter itself (`RepCounter`, `RepSettings`), the filters, and `SetEnd` (when a set looks over). Pure, no sensors. |
| `WatchCore/Sources/WatchCore/RepTrace.swift` | `RepTracker` (the counter plus the last readings), `RepPlan` (when to listen), `SetTrace` and `TraceCodec` (a recorded set), `TraceShelf` (which ones are kept), `TraceBundle` and `TraceReplay` (reading them back). |
| `Watch/MotionSampler.swift` | `RepSensor`: CoreMotion's device motion at 50 Hz, fed to a `RepTracker` on its own queue. `RepRuntime`: keeps the app running without Apple Health. `TraceStore`: the trace files on the watch and their copy to the phone. |
| `Watch/SessionStore.swift` | The section "reps counted from the wrist": the session tells the counter which set is up, takes its count onto the tile, ticks a set that ended by itself, and keeps the trace at the tick. |
| `Watch/OpenGymWatchApp.swift` | The tile's colour, `SetEndView` (the 3-2-1). |
| `App/WatchBridgePlugin.swift` | The phone's end: receives the trace files, counts them, writes the export. |
| `src/views/WatchSettings.jsx`, `src/lib/watch-settings.js`, `src/lib/watch-sync.js` | The switches and the export button. |

All paths are under `frontend/ios/App/` or `frontend/`.

## How a rep is counted

It started from RepCounter by Devesh Aggarwal (MIT, see NOTICE.md): the band-pass, the rhythm
that has to show before anything counts, the impacts that are ignored. What a rep is, is different.
RepCounter counts one burst of movement between two rests as one rep. Played against lifts made
from minimum-jerk strokes (`RepSignals.lift` in the tests), that counted ten steady bench presses
as nineteen and twelve quick curls as none: a rep done without a pause has no rest in it, and one
with a pause at the top has two bursts.

So the counter follows the wrist's line of travel instead:

1. **The band of a rep.** Each axis of the acceleration (gravity taken out by CoreMotion) goes
   through a band-pass, 0.05 to 3 Hz. Slower is drift, faster is shaking and impacts.
2. **The line of travel.** The direction that holds most of the movement lately, found as it
   goes: a running covariance of the filtered axes with one step of power iteration per reading.
   It does not matter how the watch sits on the wrist or which way the bar goes.
3. **One swing, one rep.** Along that line the acceleration swings once per rep, whether the reps
   run into each other or stop at the top, and however slow the way down is. A count fires when
   the signal has gone out past a threshold on the side a rep starts on and then crosses its
   mirror on the other side. The threshold is a share of the signal's recent size, so it fits an
   arm that swings and the faint shaking a squat sends to the wrist.
4. **A rhythm first.** Nothing counts until three swings in a row arrive at a steady tempo; then
   the count jumps to what made the rhythm and goes on live.
5. **Off the tempo.** A swing much too soon after the last one is a wobble and is dropped. One
   much too late (more than twice the tempo) is held back: it counts once the next swing follows
   at the set's tempo (a breath before the last two reps), not if nothing follows (the bar going
   back on the rack). A few late swings with a slower rhythm of their own are a new count: what
   was counted before was the walk to the bench.
6. **A long pause.** After four reps' time without a swing (never under 8 s or over 20 s) the
   next rhythm starts a new count.
7. **Impacts.** A spike of 2 g or more (plates, a bar put down) counts nothing, and neither does
   what rings after it.

`RepSettings` holds every number above. `RepSettings.general` is what all exercises use now.
`tilt` is there for exercises where the hand does not move (push-ups, pull-ups, dips): the
forearm's tilt can be followed instead of, or along with, the acceleration. Nothing sets it yet.

### The session says which set

The counter does not guess where a set starts or which exercise it is. `SessionStore.syncCounting`
runs after every change of the session and applies `RepPlan.listens`: the sensor runs while a set
with reps is up or coming up (during the rest before it too, so a set started early is counted
from its first rep), and not for a hold, cardio, an exercise with every set done, the demo, or a
workout left open for hours. Another set coming up resets the counter. The count is taken at the
tick, on the watch or on the phone.

### A set that ends by itself

`SetEnd.due`: the counter has a rhythm, the wrist is still, and it has been for 4 s or one and a
half reps at the set's tempo, whichever is longer. Never without a rhythm. The watch then shows
the 3-2-1 (`SetEndView`) before it ticks, because a tick cannot be taken back once the phone has
it. Not while a value is being edited, and not for reps set by hand.

## Recorded sets

Every set ticked while the counter was listening is kept as a `SetTrace`: the wrist's readings
from 8 s before the first counted rep to the tick (the last 60 s when no rhythm was found), the
exercise's id and name, the side, the weight, the reps logged, the reps the counter showed, and
whether the reps were changed by hand (`edited`: the lifter looked, so the number is certain).
The logged reps are the truth the counter is measured against.

- Readings: acceleration, gravity and rotation rate, nine 16-bit numbers each, about 55 kB a
  minute (`TraceCodec`). Rotation is recorded though nothing reads it yet.
- On the watch: one JSON file per set in the app's own folder, the newest 20 per exercise and
  400 in all (`TraceShelf`).
- On the phone: the watch sends each file once with `transferFile`; the phone keeps the newest
  400 in its own folder.
- Out of the phone: only through Settings → Apple Watch → Export recorded sets, which writes them
  into one file (`{"v":1,"traces":[…]}`) and opens the share sheet. Nothing is uploaded anywhere.

A trace holds no heart rate, no place and no account. It does hold how a wrist moved and what was
lifted, so only add one to the repository with its owner's consent
(`Tests/WatchCoreTests/Fixtures/traces/README.md`).

## Tests

`swift test` in `frontend/ios/App/WatchCore` runs everything; CI runs it on the Mac (`ios.yml`,
`personal-ipa.yml`). Without a Mac, the Swift image runs the same suite:

```bash
cd frontend/ios/App/WatchCore
docker run --rm -v "$PWD":/w -w /w swift:6.0 swift test --build-path /tmp/b
```

- `RepCounterTests`: what a rep is and is not, on made-up signals. `RepSignals.lift` makes reps
  from the laws of motion (a smooth stroke up, a pause, a stroke down), `RepSignals.reps` makes
  RepCounter's bursts. One test draws 400 lifts at random tempos, pauses, ranges, directions and
  noise and asks for at least 390 exact and none off by more than one.
- `RepTraceTests`: the codec, the files, the tracker, the export's format.
- `RepFixtureTests`: plays back every recorded set in `Fixtures/traces` and prints what the
  counter makes of each. It does not fail on a wrong count yet: there is no recorded set to hold
  it to. That is the next step.

The watch-side code (CoreMotion, the views) has no tests of its own; it is kept thin for that
reason.

## What is not known yet

- **Accuracy on a real wrist.** Unmeasured. The simulated lifts are clean in a way real ones are
  not.
- **Push-ups, pull-ups, dips.** The hand is fixed and the wrist hardly accelerates. Expect the
  general settings to miss them until a profile follows the tilt.
- **The first movements after the last rep.** A bar racked right at the set's tempo counts as one
  more rep. Walking off with a rhythm before the tick can add counts too.
- **Walking before a set.** A quick rhythm followed by reps at less than twice its tempo, with no
  8 s between them, runs into the set's count.
- **A sudden change of tempo in a set.** Four or more reps at over twice the tempo of the ones
  before them start a new count.
- **Without Apple Health.** Apple Health's workout session is what keeps the app running with the
  wrist down. When it is off, or refused (an app signed with a free Apple ID gets no HealthKit), a
  physical therapy extended runtime session does it instead (`RepRuntime`): an hour at most, and it
  can only start while the app is in front, so a workout started on the phone with the watch asleep
  is counted from the first time the app is looked at. Not yet tried on a watch.
- **Battery.** Device motion at 50 Hz runs for most of a workout. Not measured.

## What comes next

1. **Profiles per exercise.** The recorded sets of one exercise, played back with other settings
   (`TraceReplay.count(_:settings:)`), say which settings count that exercise best for this
   lifter: the band, the tilt's share, the threshold. A profile is a `RepSettings` kept by
   exercise id, relearned as sets come in.
2. **Knowing the exercise.** The same traces carry how the forearm is held and how it turns,
   which is enough to tell a curl from a press. First use: a hint when the set being done does
   not look like the exercise on the screen.
