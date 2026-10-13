ffi "c++" import "<mutex>";
class Unique {
    var n: i32;
    @move fn Unique(self, other: Self) = default;
}
enum Locked { Held { m: cxx::std::mutex }, Free }
enum Owned { Has { u: Unique }, Empty }
enum Text { Some { s: string }, None }
fn sink_l(@move l: Locked) { }
fn sink_o(@move o: Owned) { }
fn sink_t(@move t: Text) { }
fn read_t(t: Text) { }
fn f(l: Locked, o: Owned, t: Text) {
    sink_l(l);                              // expect: error cannot move 'Locked': its mutex payload is not movable
    sink_o(o);                              // expect: clean -- a move-only payload still moves
    sink_t(t);                              // expect: clean
    read_t(t);                              // expect: error 't' is used after being moved
}

// --- lit wiring -----------------------------------------------------------
// ClassLifecycle's facts for an ADT enum, read by MoveCheck. The ADT takes
// copyable / movable from its payload fields: a `std::mutex` payload makes it
// immovable, so a `@move` of it is refused naming the field and its variant.
// A move-only payload leaves it movable. A `string` payload moves, and the
// moved-from binding is tracked like any other.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// DIAG:      adt_payload.k:14:{{[0-9]+}}: error [SC051E]: cannot move a value of type 'Locked': the payload field 'm' of variant 'Held' is not movable
// DIAG-NEXT: adt_payload.k:6:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: type declared here
// DIAG-NOT:  adt_payload.k:15:{{[0-9]+}}: error
// DIAG-NOT:  adt_payload.k:16:{{[0-9]+}}: error
// DIAG:      adt_payload.k:17:{{[0-9]+}}: error [SC052E]: 't' is used after being moved
// DIAG-NEXT: adt_payload.k:16:{{[0-9]+}}: note
// DIAG-NOT:  {{error|warning}} [
