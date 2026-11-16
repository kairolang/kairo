// A union that declares `impl Same` conforms through that declaration: its
// `op ==` is not public, so only the declared `impl` admits it (structural
// conformance needs a public member), and the generic call compiles, links
// and runs on the union's operator.

interface Same {
    fn op ==(const self, o: Self) -> bool
}

union Bits impl Same {
    var word: u32
    var half: u16

    fn op ==(const self, o: Bits) -> bool { return self.word == o.word }
}

fn <T> eq(x: T, y: T) -> bool requires T impl Same {
    return x == y
}

fn main() -> i32 {
    var a: Bits
    a.word = 7
    var b: Bits
    b.word = 7
    var c: Bits
    c.word = 8
    if eq(a, b) && !eq(a, c) {
        return 11
    }

    return 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 11
