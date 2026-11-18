// A union meets an interface through an operator declared in its own body.

interface Same {
    fn op ==(const self, o: Self) -> bool
}

union Bits impl Same {
    var word: u32
    var half: u16
    fn op ==(const self, o: Bits) -> bool { return self.word == o.word }
}

fn <T impl Same> eq(const a: T, const b: T) -> bool {
    return a == b
}

fn main() -> i32 {
    var a: Bits
    a.word = 7
    var b: Bits
    b.word = 7
    return if (eq(a, b)) => (0) else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
