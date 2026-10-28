// A class whose member set is chosen by `eval if` on a type fact of a
// concrete record (EVAL.md 4.2b): E cannot answer it, so it waits, and the
// late fold -- after T -- keeps one branch's field and discards the other's.
// The emitted class has `kept` and `also_kept` and nothing of the untaken
// branches.
struct Plain { var x: i32 }

class Owner {
    @move fn Owner(self, other: Self) = default
    fn op delete(self) { }
}

class Holder {
    eval if is_trivially_copyable!(Plain) {
        var kept: i32
    } else {
        var dropped_a: i64
    }
    eval if is_trivially_destructible!(Owner) {
        var dropped_b: i8
    } else {
        var also_kept: i16
    }
    fn Holder(self) {
        self.kept = 1
        self.also_kept = 2
    }
}

fn main() -> i32 {
    var h = Holder()
    return h.kept + (h.also_kept as i32) - 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX --implicit-check-not=dropped_
// CXX: class Holder {
// CXX: signed int kept
// CXX: {{signed short|short}} also_kept

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
