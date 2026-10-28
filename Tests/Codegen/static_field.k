// A static field is declared in its class and defined after it as an
// inline variable: `constinit` when its initializer folded to a literal
// (constant for every instantiation), a call of its static thunk otherwise
// (dynamic initialization), `{}` with no initializer (CODEGEN.md §5).

class Counter {
    pub static count: i32 = 0
    pub static seed: u8 = 0x7F
    pub static on: bool = true
    pub static ratio: f64 = 1.5
    pub static next: i32 = Counter::seed as i32 + 1
    pub static zero: i32
    pub var id: i32 = 0
    fn Counter(self) {
        Counter::count = Counter::count + 1
        self.id = Counter::count
    }
}

class <T> Box {
    pub static n: i32 = 3
    pub var v: T
    fn Box(self, v: T) { self.v = v }
}

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

fn main() -> i32 {
    var a = Counter()
    var b = Counter()
    var n = chk((a.id == 1) && (b.id == 2) && (Counter::count == 2))
    n += chk(Counter::seed == 0x7F)
    n += chk(Counter::on)
    n += chk(Counter::ratio == 1.5)
    n += chk(Counter::next == 128)
    n += chk(Counter::zero == 0)
    n += chk(Box<i32>::n == 3)
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      class Counter {
// CXX:      static signed int count;
// CXX-NEXT: static unsigned char seed;
// CXX-NEXT: static bool on;
// CXX-NEXT: static double ratio;
// CXX:      static double __kairo_init_ratio();
// CXX:      };
// CXX-NEXT: inline constinit signed int Counter{{ ?}}::{{ ?}}count = 0;
// CXX-NEXT: inline constinit unsigned char Counter{{ ?}}::{{ ?}}seed = 127;
// CXX-NEXT: inline constinit bool Counter{{ ?}}::{{ ?}}on = true;
// CXX-NEXT: inline double Counter{{ ?}}::{{ ?}}ratio = __kairo_init_ratio{{ ?}}();
// CXX-NEXT: inline {{.*}}signed int Counter{{ ?}}::{{ ?}}next = {{.*}};
// The printer lays out every brace pair as a block, `{}` included.
// CXX-NEXT: inline signed int Counter{{ ?}}::{{ ?}}zero{{ ?}}{
// CXX-NEXT: };
// CXX:      template{{ ?}}<class T{{ ?}}>{{ ?}}inline constinit signed int Box{{ ?}}<{{ ?}}T{{ ?}}>{{ ?}}::{{ ?}}n = 3;

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 7
