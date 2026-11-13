// Through kcc: a class template bounded by operator interfaces, instantiated
// by C++ with `int` and `double`, which no Kairo row names. The bound's
// witness meets the requirements through the builtin operators, with
// Kairo's semantics (the `int` sum wraps).
pub interface Add { fn op + (const self, const o: Self) -> Self }
pub interface Mul { fn op * (const self, const o: Self) -> Self }

pub class <T> Vec2 requires T impl Mul && T impl Add {
    pub var x: T
    pub var y: T

    pub inline fn dot(const self, const o: Vec2<T>) -> T { return self.x * o.x + self.y * o.y }
}

// --- lit wiring ---
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: printf '#include "%s"\nint main() {\n  kcc_builtin_operator_bound::Vec2<int> a; a.x = 2; a.y = 3;\n  kcc_builtin_operator_bound::Vec2<int> b; b.x = 4; b.y = 5;\n  kcc_builtin_operator_bound::Vec2<double> c; c.x = 0.5; c.y = 2.0;\n  kcc_builtin_operator_bound::Vec2<double> d; d.x = 2.0; d.y = 0.25;\n  kcc_builtin_operator_bound::Vec2<int> m; m.x = 2147483647; m.y = 0;\n  kcc_builtin_operator_bound::Vec2<int> one; one.x = 2; one.y = 0;\n  if (a.dot(b) != 23 || c.dot(d) != 1.5 || m.dot(one) != -2) return 1;\n  return 7;\n}\n' > %t.d/host.cc
// RUN: %kcc %t.d/host.cc -o %t.d/main
// RUN: %t.d/main; test $? -eq 7
