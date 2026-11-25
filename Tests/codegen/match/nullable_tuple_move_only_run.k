// The parts of a nullable tuple of move-only values are moved, never
// copied, when `var (x, y) = unwrap!(...)` destructures a local or a
// temporary and when a `case var v` binder takes the payload of a match.

var moves: i32 = 0

class Mv {
    pub var n: i32 = 0

    pub fn Mv(self, n: i32) {
        self.n = n
    }

    @move
    pub fn Mv(self, other: Self) {
        self.n  = other.n
        other.n = -1
        moves += 1
    }
}

fn pair() -> (Mv, Mv)? {
    return (Mv(1), Mv(2))
}

fn names() -> (string, string)? {
    return ("a", "bc")
}

fn from_local() -> i32 {
    var p? = pair()
    var (x, y) = unwrap!(p)
    return x.n * 10 + y.n
}

fn from_temp() -> i32 {
    var (x, y) = unwrap!(pair())
    return x.n * 10 + y.n
}

fn by_case() -> i32 {
    var p? = pair()
    var r: i32 = match p {
        case null => 0
        case var v => v.0.n * 10 + v.1.n
    }

    return r
}

fn strings() -> usize {
    var p? = names()
    var (x, y) = unwrap!(p)
    var q? = names()
    var r: usize = match q {
        case null => 0
        case var v => v.0.size() + v.1.size()
    }

    return x.size() + y.size() + r
}

fn main() -> i32 {
    if from_local() != 12 {
        return 1
    }

    if from_temp() != 12 {
        return 2
    }

    if by_case() != 12 {
        return 3
    }

    if strings() != 6 {
        return 4
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe
