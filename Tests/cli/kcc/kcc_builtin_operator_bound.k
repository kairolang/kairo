// Through kcc: a class template bounded by operator interfaces, instantiated
// by C++ with `int` and `double`, which no Kairo row names. The bound's
// witness meets the requirements through the builtin operators, with
// Kairo's semantics (the `int` sum wraps, `INT_MIN / -1` is `INT_MIN`). The
// constructor asserts the bounds' concepts for the C++ arguments.
pub interface Add { fn op + (const self, const o: Self) -> Self }
pub interface Mul { fn op * (const self, const o: Self) -> Self }
pub interface Div { fn op / (const self, const o: Self) -> Self }

pub class <T> Vec2 requires T impl Mul && T impl Add {
    pub var x: T
    pub var y: T

    pub inline fn Vec2(self, x: T, y: T) {
        self.x = x
        self.y = y
    }

    pub inline fn dot(const self, const o: Vec2<T>) -> T { return self.x * o.x + self.y * o.y }
}

pub inline fn <T impl Div> quo(const a: T, const b: T) -> T { return a / b }

// --- lit wiring ---
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: printf '#include "%s"\nnamespace g = kcc_builtin_operator_bound;\nint main() {\n  g::Vec2<int> a(2, 3), b(4, 5), m(2147483647, 0), two(2, 0);\n  g::Vec2<double> c(0.5, 2.0), d(2.0, 0.25);\n  int lo = -2147483647 - 1;\n  if (a.dot(b) != 23 || c.dot(d) != 1.5 || m.dot(two) != -2) return 1;\n  if (g::quo(lo, -1) != lo || g::quo(7.0, 2.0) != 3.5) return 2;\n  return 7;\n}\n' > %t.d/host.cc
// RUN: %kcc %t.d/host.cc -o %t.d/main
// RUN: %t.d/main; test $? -eq 7
