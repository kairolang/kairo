// A `const` parameter of a type with no copy and no move (an imported
// class whose transfer constructors are deleted) takes its argument by
// reference even when a later argument has an effect and the argument is
// bound ahead of the call to keep left-to-right order: it is bound as a
// borrow, never as a snapshot the type cannot make.

ffi "c++" import "no_transfer_borrow.h"

class Holder {
    var b: Pinned<i32, 4>
}

fn count(const b: Pinned<i32, 4>, extra: i32) -> i32 {
    return (b.size() as i32) * 10 + extra
}

fn add(p: unsafe *Pinned<i32, 4>, v: i32) -> i32 {
    p->push_back(v)
    return v
}

// The deref is bound first; the second argument appends through the same
// pointer, so the callee sees the appended element: a borrow, not a copy.
fn through_ptr(p: unsafe *Pinned<i32, 4>) -> i32 {
    return count(*p, add(p, 1))
}

// A field reached through a pointer, beside an effectful argument.
fn through_field(h: *Holder, q: unsafe *Pinned<i32, 4>) -> i32 {
    return count(h->b, if (q->is_empty()) => (0) else => 2)
}

class <T: type> Parser {
    var k: i32 = 0

    fn classify(self, const args: Pinned<i32, 4>, any: bool) -> i32 {
        if !any {
            return 0
        }
        return args[0] + (args.size() as i32)
    }

    fn run(self, args: unsafe *Pinned<i32, 4>, other: unsafe *Pinned<i32, 4>) -> i32 {
        return self.classify(*args, !other->is_empty())
    }
}

class Impl {
    var z: i32 = 0
}

fn main() -> i32 {
    var h = Holder()
    h.b.push_back(5)
    var a = through_ptr(unsafe &h.b)   // 2 elements after the append: 21
    var f = through_field(&h, unsafe &h.b) // 2 elements: 22
    var p = Parser<Impl>()
    var c = p.run(unsafe &h.b, unsafe &h.b) // 5 + 2 = 7
    return a + f + c                  // 50
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: { %kairo -fduck-generics %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 50
