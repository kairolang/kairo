// `@create T { field: value }` builds one object, so a T with a destructor
// is destroyed once, by its `@destroy`. The initializer is a temporary that
// alloc.k's create forwards to the construction, which moves from it, and a
// move is destructive (language reference, Ownership: Moved-From State): the
// destructor runs once, on the object that owns the value last, so the
// moved-from temporary's `op finally` must not run as well. It does today,
// for the sugar and for the call it stands for (`create<T>(T { ... })`)
// alike: a temporary forwarded through create's argument pack is destroyed
// after the move, so `dropped` is 2 for each form.
// XFAIL: *

static dropped: i32 = 0

struct Counted {
    pub var v: i32
    fn op finally(self) { dropped = dropped + 1 }
}

fn main() -> i32 {
    var *c = @create Counted { v: 7 }
    var v = c->v
    @destroy c
    if v != 7 { return 10 }
    return dropped
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 1
