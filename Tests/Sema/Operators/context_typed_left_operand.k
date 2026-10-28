// An operand with no type of its own -- an untyped literal, a list literal,
// `.V` -- takes the OTHER operand's type, whichever side it is on: the typed
// operand is typed first and is the expected type of the other
// (RESOLUTION.md "Operators"; GitHub #83). Before, only a RIGHT operand
// took the left's: `1 + b` was an `i32 + u8` unification error waiting to
// happen and `.North == d` was SC123E.
//
// A shift's result is its left operand's type, so a literal left operand
// takes the expected type when there is one, else an integer count's
// (`1 << 4u8` is a u8 shift, USER 2026-10-28). Two context-typed operands
// keep their defaults. The inferred types below are the whole assertion.

enum Dir { North, South }

fn main() -> i32 {
    var b: u8 = 3
    var s: i16 = -2
    var f: f32 = 1.5
    var w: u64 = 9
    var big: i64 = 1
    var huge: u128 = 7
    var ineg: i8 = -3
    var arr: [u8; 2] = [1, 2]
    var d = Dir::North
    var dn: Dir? = Dir::South

    var add = 1 + b
    var sub = 200 - b
    var mul = 2 * s
    var div = 100 / w
    var rem = 7 % b
    var band = 0xF0 & b
    var bor = 1 | s
    var bxor = 0xFF ^ b
    var shl = 1 << b
    var shr = 128 >> b
    var shl_sfx = 1 << 4u8
    var shl_wide = 1 << w
    var neg = -1 * s
    var wide = 5000000000 - big
    var wide128 = 18446744073709551616 + huge
    var narrow = -128 + ineg
    var fmul = 2.0 * f
    var fadd = 0.5 + f
    var eq = 3 == b
    var lt = -1 < s
    var ge = 2.5 >= f
    var list = [1, 2] == arr
    var dot = .North == d
    var dotne = .South != d
    var dotid = .South === dn

    // Both sides context-typed: the defaults, as before.
    var both = 1 + 2
    var bothf = 1.0 * 2.0
    var bothshl = 1 << 4

    // A typed LEFT operand: unchanged. A shift's count stays its own integer.
    var r_add = b + 1
    var r_shl = b << 1
    var r_dot = d == .South
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(SEMA) mode=sema sections=inferred-decls -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}Operators/context_typed_left_operand.k =====
// SEMA: -- inferred decls --
// SEMA-NEXT:   d : Dir
// SEMA-NEXT:   add : u8
// SEMA-NEXT:   sub : u8
// SEMA-NEXT:   mul : i16
// SEMA-NEXT:   div : u64
// SEMA-NEXT:   rem : u8
// SEMA-NEXT:   band : u8
// SEMA-NEXT:   bor : i16
// SEMA-NEXT:   bxor : u8
// SEMA-NEXT:   shl : u8
// SEMA-NEXT:   shr : u8
// SEMA-NEXT:   shl_sfx : u8
// SEMA-NEXT:   shl_wide : u64
// SEMA-NEXT:   neg : i16
// SEMA-NEXT:   wide : i64
// SEMA-NEXT:   wide128 : u128
// SEMA-NEXT:   narrow : i8
// SEMA-NEXT:   fmul : f32
// SEMA-NEXT:   fadd : f32
// SEMA-NEXT:   eq : bool
// SEMA-NEXT:   lt : bool
// SEMA-NEXT:   ge : bool
// SEMA-NEXT:   list : bool
// SEMA-NEXT:   dot : bool
// SEMA-NEXT:   dotne : bool
// SEMA-NEXT:   dotid : bool
// SEMA-NEXT:   both : i32
// SEMA-NEXT:   bothf : f64
// SEMA-NEXT:   bothshl : i32
// SEMA-NEXT:   r_add : u8
// SEMA-NEXT:   r_shl : u8
// SEMA-NEXT:   r_dot : bool
// SEMA-NEXT: -- interface composition --
// END-GENERATED-CHECKS(SEMA)
