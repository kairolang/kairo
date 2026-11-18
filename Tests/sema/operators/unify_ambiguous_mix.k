// SC033E said "neither converts implicitly to the other" for `char`
// mixed with `u32`, where each converts to the other: the mix is ambiguous,
// not unconvertible. A pair where neither converts keeps the old wording.

fn main() -> i32 {
    var c: char = 'a'
    var u: u32  = 1
    var i: i8   = 1
    var e = c == u
    var s = c + u
    var n = u + i
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: unify_ambiguous_mix.k:9:13: error [SC033E]: operands 'char' and 'u32' do not unify; each converts implicitly to the other, so the mix is ambiguous
// CHECK-NEXT: note [I900N]: cast one side explicitly with 'as' to choose the result type
// CHECK: unify_ambiguous_mix.k:10:13: error {{.*}}'char' and 'u32'
// CHECK: unify_ambiguous_mix.k:11:13: error [SC033E]: operands 'u32' and 'i8' do not unify; neither converts implicitly to the other
