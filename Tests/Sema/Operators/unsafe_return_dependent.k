// SC114E / SC113E hold in a generic class too: `-> unsafe *T` is an
// unsafe pointer whatever T is, so the dependent result is checked at the
// definition instead of being left to an instantiation that never checks
// it. The check does not return early on a dependent result, so
// Compiler/Memory/ArenaList.k's `op [] -> unsafe *T` shape is caught.
// A dependent result of any other shape is still the
// instance's to check.

class <T> Arena {
    var p: unsafe *T = &null
    fn op [] (const self, i: usize) -> unsafe *T { return self.p }
// DIAG: unsafe_return_dependent.k:[[@LINE-1]]:5: error [SC114E]: 'op []' cannot return 'unsafe *T'
    fn op -> (self) -> unsafe *T { return self.p }
// DIAG: unsafe_return_dependent.k:[[@LINE-1]]:5: error [SC113E]: 'op ->' must return a pointer: '*T' or '*const T'
}

class <T> Fine {
    var v: T
    fn op [] (const self, i: usize) -> *const T { return &self.v }
    fn op -> (self) -> *T { return &self.v }
}

class <T> Value {
    var v: T
    fn op [] (const self, i: usize) -> T { return self.v }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
