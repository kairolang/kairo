// A vector literal, then push and indexing (collections.mdx, Vectors): `var
// nums: [i32] = [1, 2, 3]` owns a heap copy of its elements.

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
