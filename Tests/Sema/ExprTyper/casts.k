// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// The `as` family (ExprTyper / CastTyping). One line per rung of the ladder,
// and one per way off it.
//
// The written target is the result type, always. What differs between the
// rungs is what the cast is ALLOWED to do to get there: a widening is a
// no-op the compiler would have done anyway (and says so), a downcast is a
// runtime check, and a reinterpret needs `unsafe` because it discards what
// the type system knew about the value.

class Base { virtual fn v(self) -> i32 { return 0 } }
class Derived derives Base { }
class Unrel { }

fn accepted(b: *Base, d: *Derived, i: i32, f: f64, p: *i32) {
    var widen    = i as i64;         // picks widen's type: not redundant
    var narrow   = i as u8;
    var to_int   = f as i32;
    var upcast   = d as *Base;       // same
    var down     = b as *Derived;    // checked: panics on a miss
    var down_opt = b as (*Derived)?; // checked: null on a miss
    var addr     = p as usize;
}

fn in_unsafe(p: *i32) {
    unsafe {
        var reinterp = p as unsafe *u8;
    }
}

// A widening is redundant only where the slot already takes the source.
fn take_i64(x: i64) { }
fn slots(s: i16, d: *Derived) -> *Base {
    take_i64(s as i64);               // the parameter widens it anyway: linted
    return d as *Base;                // the return does too: linted
}

// An operator operand is not a slot: the cast picks the width the operator
// runs at, and dropping it here would lose the high byte.
fn shifted(b: u8) -> u16 { return (b as u16) << 8 }

fn rejected(b: *Base, i: i32, p: *i32) {
    var e1 = b as *Unrel;           // unrelated records
    var e2 = p as u8;               // a pointer is usize-wide or nothing
    var e3 = i as *i32;             // no safe pointer out of an integer
    var e4 = p as unsafe *u8;       // reinterpret outside an unsafe context
    var e5 = b as static *Derived;  // a static downcast is a reinterpret
}

// DIAG-NOT: redundant cast: 'i32'
// DIAG-NOT: redundant cast: 'u8'
// DIAG: warning{{.*}}redundant cast: 'i16' converts to 'i64' implicitly
// DIAG: warning{{.*}}redundant cast: '*Derived' converts to '*Base' implicitly
// DIAG-NOT: redundant cast
// DIAG: error{{.*}}'Base' and 'Unrel' are unrelated; use 'as unsafe *' to reinterpret
// DIAG: error{{.*}}a pointer converts to 'usize' only
// DIAG: error{{.*}}cannot cast the integer type 'i32' to the safe pointer '*i32'
// DIAG: error{{.*}}cast to 'unsafe *u8' requires an unsafe context
// DIAG: note{{.*}}wrap the expression in 'unsafe { ... }'
// DIAG: error{{.*}}static downcast from '*Base' to '*Derived' is not allowed
// DIAG: note{{.*}}write 'as *X' for a checked cast that panics

// SEMA: -- inferred decls --
// SEMA:      widen : i64
// SEMA-NEXT: narrow : u8
// SEMA-NEXT: to_int : i32
// SEMA-NEXT: upcast : *Base
// SEMA-NEXT: down : *Derived
// SEMA-NEXT: down_opt : *Derived?
// SEMA-NEXT: addr : usize
// `unsafe *u8` is a DIFFERENT type from `*u8`, not a qualifier on one, and
// the dump is where that is visible.
// SEMA-NEXT: reinterp : unsafe *u8
