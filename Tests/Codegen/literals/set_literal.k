// A set literal (collections.mdx, Sets): `var primes: {i32} = {2, 3, 5, 7,
// 11}` builds a hash set.
//
// ListLiteralLowering builds it as `HashSet(<the elements as a slice>)`
// (Lib/builtin/containers/hash_set.k).
//

fn main() -> i32 {
    var primes: {i32} = {2, 3, 5, 7, 11}
    if (primes.size() != 5) || !primes.contains(7) || primes.contains(4) { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
