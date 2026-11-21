// `x ?? y` takes the payload out of `x` when it is not null. A payload that
// cannot be copied moves out of a local or by-value parameter read for the
// last time; every other left operand is SC182E, with the `x?.copy()`
// fix-it where the payload copies itself. The right operand is the value
// when `x` is null, like an `if` arm: a local moves into the result (a
// later read is SC052E), any other place is SC182E.

class Box {
    pub var s: string? = "x"
    pub var t: string  = "t"
    fn Box(self) { }
}

fn field(b: Box) -> usize {
    return (b.s ?? "").size()
}

fn through(b: *Box) -> usize {
    return (b->s ?? "").size()
}

fn konst(const r: string?) -> usize {
    return (r ?? "").size()
}

fn shown(const r: string?) -> string { return "" }

fn reads_itself(r: string?) -> usize {
    return (r ?? shown(r)).size()
}

fn next_turn(r: string?) -> usize {
    var n: usize = 0
    for var i = 0; i < 2; ++i {
        n += (r ?? "").size()
    }
    return n
}

fn address(r: string?) -> usize {
    var p = &r
    return (r ?? "").size()
}

fn right_field(r: string?, b: Box) -> usize {
    return (r ?? b.t).size()
}

fn right_const(r: string?, const s: string) -> usize {
    return (r ?? s).size()
}

fn right_read_again(r: string?, s: string) -> usize {
    var x = r ?? s
    return x.size() + s.size()
}

fn copied(r: string?, b: Box) -> usize {
    var x = r?.copy() ?? ""
    var y = b.s?.copy() ?? ""
    return x.size() + y.size() + (r ?? "").size()
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:      coalesce_move_only_refused.k:15:13: error [SC182E]: cannot copy a value of type 'string': '??' takes the value out of 'b.s' when it is not null, and that value cannot be copied
// CHECK-NEXT: coalesce_move_only_refused.k:15:13: note [I900N]: 'b.s' is not a local variable or by-value parameter read for the last time here, so it cannot be moved into the result
// CHECK-NEXT: coalesce_move_only_refused.k:15:16: note [I900N]: 'string' has a 'copy' method: write 'b.s?.copy()' to copy the value
// CHECK-NEXT: fix-it:"{{.*}}":{15:16-15:16}:"?.copy()"
// CHECK:      coalesce_move_only_refused.k:19:13: error [SC182E]: {{.*}}'b->s' when it is not null
// CHECK-NEXT: coalesce_move_only_refused.k:19:13: note [I900N]: 'b->s' is not a local variable
// CHECK:      fix-it:"{{.*}}":{19:17-19:17}:"?.copy()"
// CHECK:      coalesce_move_only_refused.k:23:13: error [SC182E]: {{.*}}'??' takes the value out of 'r'
// CHECK-NEXT: coalesce_move_only_refused.k:23:13: note [I900N]: 'r' is const, so it cannot be moved into the result
// CHECK:      coalesce_move_only_refused.k:29:13: error [SC182E]: {{.*}}'??' takes the value out of 'r'
// CHECK-NEXT: coalesce_move_only_refused.k:29:13: note [I900N]: The right operand reads 'r' too
// CHECK:      coalesce_move_only_refused.k:35:15: error [SC182E]: {{.*}}'??' takes the value out of 'r'
// CHECK-NEXT: coalesce_move_only_refused.k:35:15: note [I900N]: 'r' is read again later
// CHECK:      coalesce_move_only_refused.k:35:15: note [I900N]: read again here
// CHECK:      coalesce_move_only_refused.k:42:13: error [SC182E]: {{.*}}'??' takes the value out of 'r'
// CHECK-NEXT: coalesce_move_only_refused.k:42:13: note [I900N]: The address of 'r' is taken in this function
// CHECK:      coalesce_move_only_refused.k:46:18: error [SC182E]: cannot copy a value of type 'string': '??' yields its right operand 'b.t' when the left one is null, and that value cannot be copied
// CHECK-NEXT: coalesce_move_only_refused.k:46:18: note [I900N]: 'b.t' is not a local variable or by-value parameter
// CHECK:      fix-it:"{{.*}}":{46:21-46:21}:".copy()"
// CHECK:      coalesce_move_only_refused.k:50:18: error [SC182E]: {{.*}}right operand 's'
// CHECK-NEXT: coalesce_move_only_refused.k:50:18: note [I900N]: 's' is const
// CHECK:      coalesce_move_only_refused.k:55:23: error [SC052E]: 's' is used after being moved
// CHECK-NEXT: coalesce_move_only_refused.k:54:18: note [I900N]: 's' was moved here, into the value of '??'
