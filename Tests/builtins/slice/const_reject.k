// A `[const T;]` has the read forms only: every member that writes is
// declared on the primary Slice, so on a const-element slice it is not
// found at the call.

fn by_desc(a: *const i32, b: *const i32) -> Ordering {
    return *b <=> *a
}

fn f(s: [const i32;]) {
    s.reverse()
    s.rotate(1)
    s.swap(0, 1)
    s.sort()
    s.sort_unstable()
    s.sort_by(by_desc)
    s.fill(0)
    var *p? = s.get_mut(0)
    var (a, b) = s.split_at_mut(1)
    for q in s.iter_mut() { }
    s[0] = 4
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: const_reject.k:10:7: error [R025E]: no member named 'reverse' in 'Slice'
// CHECK: const_reject.k:11:7: error [R025E]: no member named 'rotate' in 'Slice'
// CHECK: const_reject.k:12:7: error [R025E]: no member named 'swap' in 'Slice'
// CHECK: const_reject.k:13:7: error [R025E]: no member named 'sort' in 'Slice'
// CHECK: const_reject.k:14:7: error [R025E]: no member named 'sort_unstable' in 'Slice'
// CHECK: const_reject.k:15:7: error [R025E]: no member named 'sort_by' in 'Slice'
// CHECK: const_reject.k:16:7: error [R025E]: no member named 'fill' in 'Slice'
// CHECK: const_reject.k:17:17: error [R025E]: no member named 'get_mut' in 'Slice'
// CHECK: const_reject.k:18:20: error [R025E]: no member named 'split_at_mut' in 'Slice'
// CHECK: const_reject.k:19:16: error [R025E]: no member named 'iter_mut' in 'Slice'
// CHECK: const_reject.k:20:5: error [SC071E]: cannot assign to a const place
