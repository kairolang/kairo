// A constructor that initializes a const field. C++ wants the value at the
// mem-initializer list, so the body is split at the last const-field
// assignment: S_pre fills slots in a static pre-function, a private
// constructor builds the members from them and runs the rest, and the
// declared constructor delegates (CODEGEN.md §6). Covered: branches, a var
// field assigned on one path only (it keeps its default otherwise), a local
// S_pre declares and the rest reads, a read of a const already initialized,
// a method call once the object exists, and a generic record.

fn twice(n: i32) -> i32 { return n * 2 }

class F {
    pub const x: i32
    fn F(self, x: i32) { if x < 0 { self.x = 0 } else { self.x = x } }
}

class Config {
    pub const port: i32
    pub const scale: i32
    pub var retries: i32 = 3
    pub var log: i32 = 0
    fn Config(self, p: i32, env: bool) {
        var base = twice(p)
        if env {
            self.port = base
            self.retries = 5
        } else {
            self.port = p
        }
        self.scale = self.port + 1
        self.log = base + self.scale
        self.bump()
    }
    fn bump(self) { self.log = self.log + 1 }
}

class <T> Wrap {
    pub const v: T
    fn Wrap(self, v: T) { self.v = v }
}

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

fn main() -> i32 {
    var n = chk(F(-3).x == 0)
    n += chk(F(4).x == 4)
    var a = Config(10, true)        // base 20, port 20, retries 5, scale 21, log 41 + 1
    n += chk(a.port == 20)
    n += chk(a.retries == 5)
    n += chk(a.scale == 21)
    n += chk(a.log == 42)
    var b = Config(7, false)        // base 14, port 7, retries 3, scale 8, log 22 + 1
    n += chk(b.port == 7)
    n += chk(b.retries == 3)
    n += chk(b.scale == 8)
    n += chk(b.log == 23)
    n += chk(Wrap<i32>(5).v == 5)
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// The class declares the slot record, the pre-function and the slot
// constructor, privately, beside the declared constructor.
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      template{{ ?}}<class T{{ ?}}>{{ ?}}using __kairo_lref
// CXX:      struct __kairo_slot
// CXX:      class F {
// CXX:      const signed int x;
// CXX:      F(signed int x) noexcept;
// CXX:      private{{ ?}}:
// CXX-NEXT: struct __kairo_ci0;
// CXX-NEXT: static auto __kairo_ctor_pre0({{.*}}__kairo_ci0{{ ?}}&&{{ ?}}__kairo_s{{.*}}__kairo_lref{{.*}}x{{.*}}__kairo_ci0{{ ?}}&;
// CXX-NEXT: F({{.*}}__kairo_ci0{{ ?}}&{{ ?}}__kairo_s{{.*}}x);

// The four definitions, for F.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}ctor_const_init.k
// IR:      struct F{{ ?}}::{{ ?}}__kairo_ci0 {{[{]}}
// IR-NEXT: __kairo_slot{{.*}}x{{ ?}};
// IR:      __kairo_ctor_pre0
// IR:      __kairo_s{{ ?}}.{{ ?}}x{{ ?}}.{{ ?}}init
// IR:      return{{ ?}}static_cast<__kairo_ci0{{ ?}}&>({{ ?}}__kairo_s{{ ?}});
// IR:      x{{ ?}}({{ ?}}__kairo_s{{ ?}}.{{ ?}}x{{ ?}}.{{ ?}}take
// IR:      F{{ ?}}({{ ?}}__kairo_ctor_pre0{{ ?}}({{ ?}}__kairo_ci0{{ ?}}({{ ?}})

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 11
