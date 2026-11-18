// A plain `for` or `case` binder of a type that cannot be copied borrows its
// element in place, read-only, as a `const` binder does: reading it is
// fine, and every change to it is refused with a note that says it borrows
// and how to get a value that can be changed. A plain binder of a COPY type
// is still a copy and may be changed.

class M {
    pub var v: i32 = 0
    fn M(self, v: i32) { self.v = v }
    @move fn M(self, other: Self) { self.v = other.v }
    fn copy(const self) -> Self { return M(self.v) }
    fn bump(self) { self.v += 1 }
    fn get(const self) -> i32 { return self.v }
}

fn take(m: M) -> i32 { return m.v }
fn grow(@inout m: M) { m.v += 1 }
fn poke(p: *M) { p->v = 0 }

fn reads(const xs: [M; 2], const ps: [(M, M); 2], s: M?) -> i32 {
    var n = 0
    for x in xs {
        n += x.get() + x.v
    }

    for const x in xs {
        n += x.get()
    }

    for (a, b) in ps {
        n += a.v + b.get()
    }

    match s {
        case null { }
        case var m { n += m.get() }
    }

    var ints: [i32; 2] = [1, 2]
    for i in ints {
        i += 1
        n += i
    }

    return n
}

fn writes(@inout xs: [M; 2], s: M?) {
    for x in xs {
        x = M(3)
        x.v = 4
        x.bump()
        take(x)
        grow(&x)
        poke(&x)
    }

    match s {
        case null { }
        case var m { m.bump() }
    }
}

fn first(const xs: [M; 2]) -> M {
    for x in xs {
        return x
    }

    return M(0)
}

fn value(o: M?) -> M {
    match o {
        case null { return M(0) }
        case var v { return v }
    }
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:      binder_borrows_move_only.k:50:9: error [SC071E]: cannot assign to 'x': it borrows its element
// CHECK-NEXT: binder_borrows_move_only.k:49:9: note [I900N]: the binder 'x' borrows its element in place, read-only, because 'M' cannot be copied; bind a local to change a copy, 'var mine = x.copy()', or bind '*x' in a 'for' to change the element in place
// CHECK:      binder_borrows_move_only.k:51:9: error [SC071E]: cannot assign to a field of 'x': 'x' borrows its element
// CHECK-NEXT: binder_borrows_move_only.k:49:9: note [I900N]: the binder 'x' borrows its element in place, read-only, because 'M' cannot be copied; bind a local to change a copy, 'var mine = x.copy()', or bind '*x' in a 'for' to change the element in place
// CHECK:      binder_borrows_move_only.k:52:9: error [SC063E]: no matching overload for call to 'bump'
// CHECK-NEXT: binder_borrows_move_only.k:12:5: note [I900N]: candidate not viable: 'bump' is not const; it cannot be called on a const object
// CHECK-NEXT: binder_borrows_move_only.k:49:9: note [I900N]: the binder 'x' borrows its element in place, read-only, because 'M' cannot be copied; bind a local to change a copy, 'var mine = x.copy()', or bind '*x' in a 'for' to change the element in place
// CHECK:      binder_borrows_move_only.k:53:14: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_borrows_move_only.k:53:14: note [I900N]: 'x' borrows its element, so the transfer into a by-value parameter cannot move it away, and moving is the only transfer its type has
// CHECK-NEXT: binder_borrows_move_only.k:53:15: note [I900N]: 'M' has a 'copy' method: write 'x.copy()' for an explicit copy
// CHECK-NEXT: fix-it:"{{.*}}":{53:15-53:15}:".copy()"
// CHECK-NEXT: binder_borrows_move_only.k:49:9: note [I900N]: the binder 'x' borrows its element in place, read-only, because 'M' cannot be copied; bind a local to change a copy, 'var mine = x.copy()', or bind '*x' in a 'for' to change the element in place
// CHECK:      binder_borrows_move_only.k:54:9: error [SC063E]: no matching overload for call to 'grow'
// CHECK-NEXT: binder_borrows_move_only.k:17:1: note [I900N]: candidate not viable: parameter 'm' is '@inout' and needs a mutable lvalue of type 'M'; got 'const M'
// CHECK-NEXT: binder_borrows_move_only.k:49:9: note [I900N]: the binder 'x' borrows its element in place, read-only, because 'M' cannot be copied; bind a local to change a copy, 'var mine = x.copy()', or bind '*x' in a 'for' to change the element in place
// CHECK:      binder_borrows_move_only.k:55:9: error [SC063E]: no matching overload for call to 'poke'
// CHECK-NEXT: binder_borrows_move_only.k:18:1: note [I900N]: candidate not viable: cannot convert argument of type '*const M' to parameter 'p' of type '*M'
// CHECK-NEXT: binder_borrows_move_only.k:49:9: note [I900N]: the binder 'x' borrows its element in place, read-only, because 'M' cannot be copied; bind a local to change a copy, 'var mine = x.copy()', or bind '*x' in a 'for' to change the element in place
// CHECK:      binder_borrows_move_only.k:60:22: error [SC063E]: no matching overload for call to 'bump'
// CHECK-NEXT: binder_borrows_move_only.k:12:5: note [I900N]: candidate not viable: 'bump' is not const; it cannot be called on a const object
// CHECK-NEXT: binder_borrows_move_only.k:60:18: note [I900N]: the binder 'm' borrows its element in place, read-only, because 'M' cannot be copied; bind a local to change a copy, 'var mine = m.copy()', or bind '*m' in a 'for' to change the element in place
// CHECK:      binder_borrows_move_only.k:66:16: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_borrows_move_only.k:66:16: note [I900N]: 'x' borrows its element, so the transfer out of the function cannot move it away, and moving is the only transfer its type has
// CHECK:      fix-it:"{{.*}}":{66:17-66:17}:".copy()"
// CHECK:      binder_borrows_move_only.k:75:29: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_borrows_move_only.k:75:29: note [I900N]: 'v' borrows its element, so the transfer out of the function cannot move it away
