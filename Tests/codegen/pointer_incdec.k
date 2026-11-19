// `++it` / `--it` and the postfix forms on a safe pointer run as
// C++'s pointer increment: a loop from the vector's data() pointer to one
// past its last element, a step back from that end, a postfix whose old
// pointer is read, and a prefix whose result is the stepped pointer.

fn main() -> i32 {
    var v: [i32] = [1, 2, 3, 4]
    var r = 0
    var sum = 0
    var *b = unwrap!(v.data()); for var *it = b; it != b + v.size(); ++it { sum += *it }
    if sum == 10 { r += 1 }
    var *e = b + v.size()
    --e
    if *e == 4 { r += 2 }
    var *q = b
    var *old = q++
    if (*old == 1) && (*q == 2) { r += 4 }
    q--
    if q == b { r += 8 }
    var *w = ++q
    if (*w == 2) && (w == q) { r += 16 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 31
