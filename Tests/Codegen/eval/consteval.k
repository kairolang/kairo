// EVAL.md 1.1 / 1.2: an `eval fn` (free, method, static method) is C++
// `consteval`; an `eval` field is a static of its class, `static const T`
// in the class and `inline constexpr` at its definition. A field whose
// initializer folds is defined after the class; any other gets a consteval
// thunk and is defined right after the thunk's body. Eval bodies come
// first in the TU, so an eval binding may call an eval fn declared below
// it (Kairo declarations have no order; consteval needs the definition).

eval EARLY = late(3)                        // late is declared below

pub class Grid {
    pub eval W: i32 = 4                     // folds
    pub eval AREA: i32 = late(2) * 2        // thunk: calls an eval fn
    pub eval SCALE: f64 = 1.5               // thunk: not an integer
    pub var cells: i32
    pub eval fn count(self) -> i32 { return self.cells * Grid::W }
    pub eval fn of(n: i32) -> i32 { return n + Grid::W }
}

eval fn late(x: i32) -> i32 { return x * x + 1 }

fn main() -> i32 {
    var direct = late(4)                    // an immediate invocation: 17
    return EARLY + Grid::W + Grid::AREA + (Grid::SCALE * 2.0) as i32 + Grid::of(1) + direct
        // 10 + 4 + 10 + 3 + 5 + 17 == 49
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}consteval.k
// IR:      static const signed int W;
// IR-NEXT: static const signed int AREA;
// IR-NEXT: static const double SCALE;
// IR:      consteval signed int count() noexcept;
// IR-NEXT: static consteval signed int of(signed int n) noexcept;
// IR-NEXT: static consteval signed int __kairo_init_AREA();
// IR-NEXT: static consteval double __kairo_init_SCALE();
// IR:      inline constexpr const signed int Grid::W = 4;
// IR:      consteval signed int late(signed int x) noexcept;
// The bodies, eval ones first (free functions, then records' methods),
// then the eval bindings: late's body before the thunks that call it,
// and all of them before EARLY's definition.
// IR:      consteval signed int late(signed int x) noexcept {
// IR:      consteval signed int Grid::__kairo_init_AREA() {
// IR:      inline constexpr const signed int Grid::AREA = Grid::__kairo_init_AREA();
// IR:      inline constexpr const double Grid::SCALE = Grid::__kairo_init_SCALE();
// IR:      inline constexpr signed int const EARLY = {{.*}}late(3);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 49
