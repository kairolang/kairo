// A nullable place NOT proven non-null where an operand form reads it stays
// the nullable, and the form rejects it: never checked, checked on one path
// only, made maybe-null again by an assignment, or one bound proven and the
// other not. A range keeps its integer error, a builtin index its index
// error; `op []` / `op []=` and `in` report the read of a value that may be
// null, as a call argument does. Equality, and a subscript form whose
// parameter is the nullable, take it as it is. One error per `bad_*`, none
// per `ok_*`.

struct Span { pub var end: usize? = null }

fn bad_range_unchecked(x: usize?) -> usize {
    var t: usize = 0
    for i in 0..x { t += i }
    return t
}

fn bad_range_one_path(x: usize?, c: bool) -> usize {
    if c {
        if !x? { return 0 }
    }
    var r = 0..x
    return 0
}

fn bad_range_reassigned(x: usize?, y: usize?) -> usize {
    var z? = x
    if !z? { return 0 }
    z = y
    var r = z..=4
    return 0
}

fn bad_range_one_bound(a: usize?, b: usize?) -> usize {
    if !a? { return 0 }
    var r = a..b
    return 0
}

fn bad_slice(const line: string) -> usize {
    var sep? = line.rfind(":")
    var head = line[0..sep]
    return head.size()
}

fn bad_open_slice(const line: string, y: usize?) -> usize {
    var tail = line[y..]
    return tail.size()
}

fn bad_array_index(x: usize?) -> i32 {
    var a: [i32; 3] = [1, 2, 3]
    return a[x]
}

fn bad_vector_index(x: usize?) -> i32 {
    var v: [i32] = [1, 2, 3]
    return v[x]
}

fn bad_vector_store(x: usize?) -> i32 {
    var v: [i32] = [1, 2, 3]
    v[x] = 4
    return 0
}

fn bad_map_key(k: i32?) -> i32 {
    var m: {i32: i32} = {1: 2}
    return m[k]
}

fn bad_in(x: i32?) -> bool {
    var v: [i32] = [1, 2]
    return x in v
}

fn bad_field_index(sp: Span) -> i32 {
    var v: [i32] = [1, 2, 3]
    return v[sp.end]
}

fn ok_equality(x: i32?) -> bool {
    return x == 3
}

fn ok_checked(x: usize?) -> usize {
    if !x? { return 0 }
    var r = 0..x
    return 0
}

// A form that takes the nullable as it is is chosen with no error, though
// another form would take only the value: a read `op []` taking `usize?`
// beside a place `op []=` taking `usize`, and a place `op []=` taking
// `usize?` beside a setter taking `usize`.
class ReadNullable {
    var d: [i32; 4]
    fn ReadNullable(self) { self.d = [1, 2, 3, 4] }
    fn op [] (self, i: usize?) -> i32 { return 1 }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
}

class PlaceNullable {
    var d: [i32; 4]
    fn PlaceNullable(self) { self.d = [1, 2, 3, 4] }
    fn op [] (self, i: usize?) -> i32 { return 1 }
    fn op []= (self, i: usize?) -> *i32 { return &self.d[0] }
    fn op []= (self, i: usize, v: i32) { }
}

fn ok_read_form(x: usize?) -> i32 {
    var m = ReadNullable()
    var t = m[x]
    return t
}

fn ok_place_form(x: usize?) -> i32 {
    var m = PlaceNullable()
    m[x] = 1
    return 0
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: narrowed_operands_unproven.k:14:14: error [SC085E]: range bounds must be integers, not 'usize?'
// DIAG: narrowed_operands_unproven.k:22:13: error [SC085E]: range bounds must be integers, not 'usize?'
// DIAG: narrowed_operands_unproven.k:30:13: error [SC085E]: range bounds must be integers, not 'usize?'
// DIAG: narrowed_operands_unproven.k:36:13: error [SC085E]: range bounds must be integers, not 'usize?'
// DIAG: narrowed_operands_unproven.k:42:21: error [SC085E]: range bounds must be integers, not 'usize?'
// DIAG: narrowed_operands_unproven.k:47:21: error [SC085E]: range bounds must be integers, not 'usize?'
// DIAG: narrowed_operands_unproven.k:53:14: error [SC103E]: index must be an integer, not 'usize?'
// DIAG: narrowed_operands_unproven.k:58:14: error [SC265E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: narrowed_operands_unproven.k:56:21: note [I900N]: 'x' is a nullable parameter; it may be null on entry
// DIAG: narrowed_operands_unproven.k:63:7: error [SC265E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: narrowed_operands_unproven.k:61:21: note [I900N]: 'x' is a nullable parameter; it may be null on entry
// DIAG: narrowed_operands_unproven.k:69:14: error [SC265E]: 'k' may be null here; check it with 'if k?' first
// DIAG-NEXT: narrowed_operands_unproven.k:67:16: note [I900N]: 'k' is a nullable parameter; it may be null on entry
// DIAG: narrowed_operands_unproven.k:74:12: error [SC265E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: narrowed_operands_unproven.k:72:11: note [I900N]: 'x' is a nullable parameter; it may be null on entry
// DIAG: narrowed_operands_unproven.k:79:14: error [SC265E]: 'sp.end' may be null here; check it with 'if sp.end?' first
// DIAG-NEXT: narrowed_operands_unproven.k:10:19: note [I900N]: 'end' is declared nullable here
// DIAG-NOT: {{error|warning}}
