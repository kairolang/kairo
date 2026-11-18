// When every overload's `requires` clause is false for the arguments, the
// call has no viable candidate, and each candidate's note names the type
// and the part of its clause that is false.

interface Shout {
    fn shout(const self) -> i32
}

interface Whisper {
    fn whisper(const self) -> i32
}

class Mute {
    pub var n: i32
}

fn <T> say(const x: T) -> i32 requires T impl Shout {
    return 1
}

fn <T> say(const x: T) -> i32 requires T impl Whisper && !(T impl Shout) {
    return 2
}

fn main() -> i32 {
    var m = Mute()
    return say(m)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: overload_none_viable.k:27:12: error [SC063E]: no matching overload for call to 'say'
// CHECK-NEXT: overload_none_viable.k:17:1: note [I900N]: candidate not viable: its 'requires' clause does not hold: 'Mute' does not implement 'Shout': it has no 'shout'
// CHECK-NEXT: overload_none_viable.k:21:1: note [I900N]: candidate not viable: its 'requires' clause does not hold: 'Mute' does not implement 'Whisper': it has no 'whisper'
// CHECK-NOT: error
