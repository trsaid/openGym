# Recorded sets

Sets as a real wrist felt them, with the reps that were logged for them: the truth the rep
counter is measured against (docs/dev/REP_COUNTING.md). `RepFixtureTests` plays every `.json`
file in this folder back through the counter.

A file is what the phone exports (Settings → Apple Watch → Rep counting → Export recorded sets):
one bundle `{"v":1,"traces":[…]}`, or a single trace. Each trace holds the wrist's motion from a
little before the first rep to the tick (acceleration, gravity and rotation, 50 readings a
second), the exercise's name, the weight, the reps logged and the reps the counter showed.
Nothing else: no heart rate, no place, no account.

Only add recordings whose owner agreed to have them in a public repository.
