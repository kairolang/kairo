// A `const` parameter borrows the caller's value. A vector and a string
// cannot be copied implicitly, so a transfer by value out of such a
// parameter (initializing a local, passing it to a by-value parameter) has
// no move to fall back on and is SC182E. An `@inout` parameter in the same
// place is moved from, and the caller is left with an empty value.

fn count(xs: [string]) -> usize {
    return xs.size()
}

fn into_local(const xs: [string]) -> usize {
    var ys = xs
    return ys.size()
}

fn into_param(const xs: [string]) -> usize {
    return count(xs)
}

fn string_into_local(const s: string) -> usize {
    var t = s
    return t.size()
}

// Accepted: an explicit copy, a borrowing loop and a read.
fn copies(const xs: [string]) -> usize {
    var ys = xs.copy()
    var n: usize = 0
    for const x in xs {
        n += x.size()
    }

    return ys.size() + n + xs[0].size()
}

// The same transfer out of an `@inout` parameter compiles: it moves.
fn moves_out(@inout xs: [string]) -> usize {
    var ys = xs
    return ys.size()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: const_param_container_no_move.k:12:14: error [SC182E]: cannot copy a value of type '[string]'
// CHECK: 'xs' is const, so the transfer into 'ys' cannot move it
// CHECK: const_param_container_no_move.k:17:18: error [SC182E]: cannot copy a value of type '[string]'
// CHECK: 'xs' is const, so the transfer into a by-value parameter cannot move it
// CHECK: const_param_container_no_move.k:21:13: error [SC182E]: cannot copy a value of type 'string'
// CHECK: 's' is const, so the transfer into 't' cannot move it
