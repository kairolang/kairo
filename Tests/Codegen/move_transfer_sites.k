// GH#90: the transfer sites MoveCheck did not record, so a MOVE value was
// emitted as a copy and the program failed in clang on the deleted copy
// constructor. The operand of a user compound assignment and of a user
// subscript is an argument; an expression body's value is returned, as
// `{ return p.a }` returns it; and in a generic body a value of type `T`
// moves when the instance is MOVE. One template body serves every instance,
// so the generic transfer is cast to `T&&` only where nothing reads the
// binding again: `relay` moves, `keep` (which reads `x` after) copies,
// and so does `aliased`, whose `p = &x` still reads `x` after the transfer:
// Txt is COPY with a std::string C++ would empty on a move, so a move there
// would leave `*p` reading "".

ffi "c++" import "string"

class Str {
    pub var n: i32 = 0
    fn Str(self) { }
    fn Str(self, n: i32) { self.n = n }
    @move fn Str(self, other: Self) { self.n = other.n; other.n = 0 }
}

class Acc {
    pub var n: i32 = 0
    fn Acc(self) { }
    fn op += (self, s: Str) { self.n += s.n }
    fn op [] (self, s: Str) -> i32 { return s.n }
}

class Pair { pub var a: Str  pub var b: Str }

fn first(p: Pair) -> Str = p.a
fn <T> relay(x: T) -> i32 { var y = x; return 0 }
fn <T> keep(x: T) -> T { var y = x; return x }
fn <T> aliased(x: T, dst: *T) -> i32 { var *p = &x; var y = x; *dst = *p; return 0 }

class Txt {
    pub var v: cxx::std::string
    fn Txt(self, n: usize) { self.v.resize(n) }
}

fn main() -> i32 {
    var acc = Acc()
    var s = Str(1)
    acc += s                                    // 1
    var t = Str(2)
    var r = acc[t]                              // 2
    var p = Pair()
    p.a = Str(4)
    r += first(p).n                             // 6
    r += relay<Str>(Str(3))
    var u = Str(5)
    r += relay<Str>(u)
    var g = fn (q: Pair) -> Str = q.b
    var p2 = Pair()
    p2.b = Str(8)
    r += g(p2).n                                // 14
    r += keep<i32>(7)                           // 21
    var o = Txt(0)
    var *po = &o
    r += aliased<Txt>(Txt(3), po)
    r += o.v.size() as i32 - 3                  // 21: the alias read all of x
    return r + acc.n - 22                       // 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}move_transfer_sites.k
// IR:      first({{ ?}}::move_transfer_sites::Pair p) noexcept {
// IR-NEXT: return static_cast<{{ ?}}::move_transfer_sites::Str &&>(p.a);
// IR:      template<class T> signed int relay(T x) noexcept {
// IR-NEXT: T y = static_cast<T &&>(x);
// IR:      template<class T> T keep(T x) noexcept {
// IR-NEXT: T y = x;
// IR:      template<class T> signed int aliased(T x, T * dst) noexcept {
// IR-NOT:  T &&
// IR:      return 0;
// IR:      acc.operator +=(static_cast<{{ ?}}::move_transfer_sites::Str &&>(s));
// IR:      acc.operator[](static_cast<{{ ?}}::move_transfer_sites::Str &&>(t));
// IR:      relay<{{ ?}}::move_transfer_sites::Str>(static_cast<{{ ?}}::move_transfer_sites::Str &&>(u))
// IR:      return static_cast<{{ ?}}::move_transfer_sites::Str &&>(q.b);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
