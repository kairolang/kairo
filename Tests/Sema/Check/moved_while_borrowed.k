// A place one argument of a call borrows (a `const` or `@inout` parameter,
// the receiver of a method) and a later argument moves is an error at the
// borrowing argument: the callee would read a moved-from value. A type with
// a public copy() is offered one at the move. A borrow of a different place
// is not affected, nor a move in an earlier argument (a plain use after
// move).

class Str {
    pub var n: i32 = 0
    pub fn Str(self, n: i32) { self.n = n }
    @move pub fn Str(self, other: Self) { self.n = other.n; other.n = -1 }
    pub fn copy(const self) -> Str = Str(self.n)
    pub fn put(const self, at: i32) -> i32 = self.n + at
}

fn put(const s: Str, at: i32) -> i32 = s.n + at
fn edit(@inout s: Str, at: i32) -> i32 { s.n += at; return s.n }
fn take(s: Str) -> i32 = s.n

fn borrowed_then_moved() -> i32 {
    var s = Str(4)
    return put(s, take(s))
}

fn inout_then_moved() -> i32 {
    var s = Str(4)
    return edit(&s, take(s))
}

fn receiver_then_moved() -> i32 {
    var s = Str(4)
    return s.put(take(s))
}

fn other_place() -> i32 {
    var s = Str(4)
    var t = Str(5)
    return put(s, take(t))
}

fn moved_then_borrowed() -> i32 {
    var s = Str(4)
    return take(s) + put(s, 1)
}

fn main() -> i32 = 0

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:  error
// CHECK:      :22:16: error [SC001E]: 's' is borrowed by this argument and moved by a later argument of the same call, so the call reads a moved-from value
// CHECK-NEXT: :22:24: note [I900N]: 's' is moved here, into a by-value parameter
// CHECK-NEXT: :22:25: note [I900N]: 's' has a 'copy' method: write 's.copy()' to pass a copy instead
// CHECK-NEXT: fix-it:"{{.*}}":{22:25-22:25}:".copy()"
// CHECK-NOT:  error
// CHECK:      :27:18: error [SC001E]: 's' is borrowed by this argument and moved by a later argument of the same call
// CHECK-NOT:  error
// CHECK:      :32:12: error [SC001E]: 's' is borrowed by this argument and moved by a later argument of the same call
// CHECK-NOT:  error
// CHECK:      :43:26: error [SC052E]: 's' is used after being moved
// CHECK-NOT:  error [
