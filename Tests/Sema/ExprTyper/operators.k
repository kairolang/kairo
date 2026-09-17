// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// The binary/unary operator table (ExprTyper / OperatorTyping).
//
// Kairo does NOT have C's usual arithmetic conversions. Two operands unify
// only when one converts implicitly to the other; mixed signedness and
// int/float mixes do not, and the fix is an explicit `as` that says which
// result type was meant. `byte` is not an integer: it is bit-storage, and
// mixing it with one is an error rather than a promotion.
//
// A shift is the exception that proves the rule: the two sides are ranked
// separately, and the result is the LEFT side's type.

fn mixed(a: u32, b: i32, c: i64, d: f64, e: byte, g: u8) {
    var r1 = a + b;    // u32 + i32: no unification
    var r2 = c + d;    // i64 + f64: no unification
    var r3 = e & g;    // byte & u8: byte is not an integer
}

fn ok(b: i32, g: u8, h: i32?, i: bool, f: f64) {
    var shift  = b << g;   // the left side's type, not the right's
    var coal   = h ?? b;   // T? ?? T -> T
    var and_   = i && i;
    var eq     = b == b;
    var lt     = f < f;
    var neg    = -b;
    var not_   = !i;
    var flip   = ~b;
}

// `<=>` yields the `Ordering` lang item. The prelude puts it in scope in
// every TU, so this types as `Ordering` -- it used to report the missing item
// instead, which was the right answer only while nothing imported builtin.
fn spaceship(b: i32) {
    var cmp = b <=> b;
}

// DIAG: error{{.*}}operands 'u32' and 'i32' do not unify
// DIAG: note{{.*}}cast one side explicitly with 'as' to choose the result type
// DIAG: error{{.*}}operands 'i64' and 'f64' do not unify
// DIAG: error{{.*}}bitwise operators require two integers, two bytes, or two bools, not 'byte' and 'u8'
// DIAG-NOT: error{{.*}}needs the 'Ordering' lang item

// The prelude puts the builtin TUs in the dump ahead of this one, and each of
// them has an `-- inferred decls --` section of its own. Anchor on THIS file's
// header first, or the -NEXT chain below walks off a builtin dump instead.
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}operators.k =====
// SEMA: -- inferred decls --
// SEMA:      shift : i32
// SEMA-NEXT: coal : i32
// SEMA-NEXT: and_ : bool
// SEMA-NEXT: eq : bool
// SEMA-NEXT: lt : bool
// SEMA-NEXT: neg : i32
// SEMA-NEXT: not_ : bool
// SEMA-NEXT: flip : i32
// SEMA-NEXT: cmp : Ordering
