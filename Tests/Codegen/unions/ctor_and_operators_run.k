// A union's constructor and operator overloads compile and run.

union Bits {
    var word:  i32
    var ratio: f32

    fn Bits(self, seed: i32) {
        self.word = seed + 1
    }

    fn op +(self, other: Bits) -> i32 {
        return self.word + other.word
    }

    fn op ==(self, other: Bits) -> bool {
        var same = self.word == other.word
        return same
    }
}

fn main() -> i32 {
    var a = Bits(1)
    var b = Bits(2)
    var sum = a + b
    if a == b {
        return 1
    }

    return sum - 5
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe; test $? -eq 0
