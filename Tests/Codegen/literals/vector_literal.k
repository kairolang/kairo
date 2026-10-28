// A vector literal, then push and indexing (collections.mdx, Vectors): `var
// nums: [i32] = [1, 2, 3]` owns a heap copy of its elements.
//
// XFAIL: *
// Ticket "[Lib/Codegen] Vectors: a vector literal does not link, `v[i]`
// ICEs, and there is no `push`" (private/IMPORTANT/TICKETS.TXT,
// 2026-10-26). Today `nums.push(4)` is R025E "no member named 'push' in
// 'Vector'"; without it, `nums[0]` ICEs ("EmitIR: `[]` on a record;
// OperatorLowering owns it"); and the literal alone type-checks and
// compiles but does not link (L001E "undefined symbol:
// builtin::containers::vector::Vector<int>::Vector(
// builtin::containers::slice::Slice<int>)": the built-in vector constructors are not implemented). When it XPASSes,
// delete the XFAIL -- the run below is already the real assertion.

fn main() -> i32 {
    var nums: [i32] = [1, 2, 3]
    nums.push(4)
    return nums[0] + nums[3]                    // 1 + 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
