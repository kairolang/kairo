// A field whose type has no default is built by its constructor's first
// whole write, which becomes its C++ mem-initializer through the split
// constructor (CODEGEN.md §6), as a const field's one write does. Covered:
// an enum with payloads chosen on a branch, an array of them built whole
// and later written by element, a `bool`, a record with no default
// constructor, a const field beside them, a method call once the object
// exists, a later whole reassignment, and an array field with a list-literal
// default, whose C++ default member initializer lists one thunk per element.

enum Frame {
    Burst { base: i32, count: i32 },
    Code  { status: i32 },
    Idle,
}

fn weight(f: Frame) -> i32 = match f {
    case .Burst(const base, const count) => base * count
    case .Code(const status) => status
    default => 0
}

class Token {
    pub var n: i32
    fn Token(self, n: i32) { self.n = n }
}

class Batch {
    pub const id: i32
    pub var head: Frame
    pub var frames: [Frame; 3]
    pub var ok: bool
    pub var tok: Token
    pub var log: i32 = 0
    pub var spare: [Frame; 2] = [.Code { status: 7 }, .Idle]

    fn Batch(self, a: i32, burst: bool) {
        if burst { self.head = .Burst { base: a, count: 2 } } else { self.head = .Code { status: a } }
        self.frames = [.Idle, .Code { status: a + 1 }, .Burst { base: 3, count: 3 }]
        self.ok = burst
        self.tok = Token(a * 10)
        self.id = a
        self.bump()
        self.frames[0] = .Code { status: 5 }
        self.head = .Code { status: weight(self.head) + 1 }
    }

    fn bump(self) { self.log = self.log + weight(self.frames[2]) }

    fn total(self) -> i32 {
        var t = weight(self.head) + self.tok.n + self.log + self.id
        for var i: usize = 0; i < 3; ++i { t += weight(self.frames[i]) }
        t += weight(self.spare[0]) + weight(self.spare[1])
        return t
    }
}

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

fn main() -> i32 {
    // head: Burst 4*2 = 8, then Code 9. frames: Code 5, Code 5, Burst 9.
    // tok 40, log 9, id 4, spare 7: 9 + 40 + 9 + 4 + 19 + 7 = 88.
    var b = Batch(4, true)
    var n = chk(b.total() == 88)
    n += chk(b.ok)
    // head: Code 6, then Code 7. frames: 5, 7, 9. tok 60, log 9, id 6,
    // spare 7: 7 + 60 + 9 + 6 + 21 + 7 = 110.
    var c = Batch(6, false)
    n += chk(c.total() == 110)
    n += chk(!c.ok)
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The array field's slot hands its value over element by element, and its
// list-literal default is one thunk call per element.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}ctor_field_init.k
// IR:      struct __kairo_slot<T[N]>
// IR:      spare{{\[}}2{{\]}}{{ ?}}={{ ?}}{{[{]}}
// IR-NEXT: __kairo_init0_spare{{ ?}}({{ ?}}){{ ?}},{{ ?}}__kairo_init1_spare{{ ?}}({{ ?}})
// IR:      __kairo_s{{ ?}}.{{ ?}}head{{ ?}}.{{ ?}}put{{ ?}}(
// IR:      __kairo_s{{ ?}}.{{ ?}}frames{{ ?}}.{{ ?}}init{{ ?}}(
// IR:      head{{ ?}}({{ ?}}__kairo_s{{ ?}}.{{ ?}}head{{ ?}}.{{ ?}}take{{ ?}}({{ ?}}){{ ?}}){{ ?}},{{ ?}}frames{{ ?}}{{[{]}}
// IR-NEXT: __kairo_s{{ ?}}.{{ ?}}frames{{ ?}}.{{ ?}}take{{ ?}}({{ ?}}){{\[}}0{{\]}}{{ ?}},{{.*}}take{{ ?}}({{ ?}}){{\[}}2{{\]}}

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 4
