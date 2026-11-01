// An interface requirement may carry a calling convention, and a conformer
// matches it exactly: the convention is part of the signature structural
// conformance compares. `Good` conforms; `Bad`, whose `grow` has the
// default convention, does not.

priv interface Grower {
    @preserve_most
    fn grow(const self, n: u64) -> u64
}

priv class Good {
    var base: u64
    fn Good(self, b: u64) { self.base = b }

    @preserve_most
    fn grow(const self, n: u64) -> u64 { return self.base + n }
}

priv class Bad {
    var base: u64
    fn Bad(self, b: u64) { self.base = b }

    fn grow(const self, n: u64) -> u64 { return self.base + n }
}

priv fn <T impl Grower> drive(a: T) -> u64 { return a.grow(1) }

fn main() -> i32 {
    var g = Good(1)
    var b = Bad(1)
    return (drive(g) + drive(b)) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --target=x86_64-linux-gnu 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: callconv_interface.k:31:{{[0-9]+}}: error [SC001E]: 'Bad' does not conform to 'Grower': no member 'grow' with the requirement's signature
