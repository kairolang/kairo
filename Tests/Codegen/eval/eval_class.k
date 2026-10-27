// Eval classes (EVAL.md §7): a class with an eval constructor is usable at
// compile time. `eval H = Hasher(...)` is a constexpr object, an eval
// method is consteval and callable on it (as `const self`: an eval binding
// is const), an eval field is a class constant, and the same constructor
// builds an object at run time when its arguments are constants. A field
// default runs in the eval constructor too, so its thunk is constexpr. A
// struct literal of constants is an eval value without a constructor.
eval FNV_OFFSET: u64 = 2166136261
eval FNV_PRIME: u64 = 16777619

class Hasher {
    pub eval SEED: u64 = FNV_OFFSET
    pub var state: u64
    pub var rounds: i32 = 0
    eval fn Hasher(self, start: u64) { self.state = start }
    eval fn mix(const self, b: u64) -> u64 { return (self.state ^ b) * FNV_PRIME }
    fn runtime_only(const self) -> u64 { return self.state + 1 }
}

struct Point { pub var x: i32  pub var y: i32 }
eval ORIGIN = Point { x: 3, y: 4 }

eval H = Hasher(Hasher::SEED)
eval MIXED = H.mix(7)

fn main() -> i32 {
    var h = Hasher(5)            // an eval constructor with constant arguments, at run time
    var r = (h.runtime_only() as i32) + ORIGIN.x + ORIGIN.y   // 6 + 7
    if MIXED != 0 { r += 1 }
    if AREA == 20 { r += 0 }
    return r                     // 14
}

class Cfg {
    pub var scale: i32 = twice(2)              // a default that is a call: a constexpr thunk
    pub var w: i32
    eval fn Cfg(self, w: i32) { self.w = w }
    eval fn area(const self) -> i32 { return self.w * self.scale }
}
eval fn twice(x: i32) -> i32 { return x * 2 }
eval CFG = Cfg(5)
eval AREA = CFG.area()                          // 20

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}eval_class.k
// IR:     consteval Hasher(unsigned long start) noexcept;
// IR:     consteval unsigned long mix(unsigned long b) const noexcept;
// IR:     constexpr signed int __kairo_init_scale();
// IR:     constexpr::eval_class::Hasher const H =
// IR:     inline constexpr signed int Cfg::__kairo_init_scale() {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 14
