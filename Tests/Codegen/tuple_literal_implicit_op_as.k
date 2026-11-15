// A tuple literal's element that converts through an `@implicit op as`
// converts element by element too, at an initialization and at an
// argument; OperatorLowering writes the conversion, so TupleLowering adds
// no cast of its own to a record element.

class Meters {
    var v: i32 = 0

    fn Meters(self, v: i32) {
        self.v = v
    }

    @implicit fn op as (const self) -> i64 {
        return self.v
    }
}

fn take(t: (i64, i32)) -> i64 {
    return t.0 + t.1
}

fn main() -> i32 {
    var m = Meters(5)
    var t: (i64, i32) = (m, 1)
    // (5 + 2) + 5 + 1
    return (take((m, 2)) + t.0 + t.1 - 13) as i32
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -w -o %t.exe --cache-dir %t.d
// RUN: %t.exe
