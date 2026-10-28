// `op =` is derived from the transfer constructor. With a body it destroys
// the old value and builds the new one in its place through that
// constructor, and does nothing at all when a value is assigned to itself:
// destroying first would leave nothing to build from. C counts its copies
// and destructions and records their order, M counts its moves, Box<X> is C
// as a generic class. T, N and Poly show the other rows of the table.

var copies: i32 = 0
var moves: i32 = 0
var drops: i32 = 0
var order: i32 = 0      // one digit per event, oldest first: 1 a destruction, 2 a copy

class C {
    pub var v: i32
    pub fn C(self, v: i32) { self.v = v }
    @copy
    fn C(self, const other: Self) {
        self.v = other.v
        copies = copies + 1
        order = order * 10 + 2
    }
    fn op delete(self) {
        drops = drops + 1
        order = order * 10 + 1
    }
}

class M {
    pub var v: i32
    pub fn M(self, v: i32) { self.v = v }
    @move
    fn M(self, other: Self) {
        self.v = other.v
        moves = moves + 1
    }
    fn op delete(self) { drops = drops + 1 }
}

class <X> Box {
    pub var v: X
    pub fn Box(self, v: X) { self.v = v }
    @copy
    fn Box(self, const other: Self) {
        self.v = other.v
        copies = copies + 1
    }
    fn op delete(self) { drops = drops + 1 }
}

// Every part trivial: the derived `op =` is C++'s own.
class T {
    pub var v: i32
    pub fn T(self, v: i32) { self.v = v }
    @copy
    fn T(self, const other: Self) = default
}

// NON_TRANSFER: no `op =` at all.
class N {
    pub var v: i32
    pub fn N(self, v: i32) { self.v = v }
    @copy
    fn N(self, const other: Self) = delete
    @move
    fn N(self, other: Self) = delete
}

// Polymorphic, with a transfer body: rebuilding it in place would reset its
// vptr to its own in a derived object, so it has no `op =`.
class Poly {
    pub var v: i32
    pub fn Poly(self, v: i32) { self.v = v }
    @copy
    fn Poly(self, const other: Self) { self.v = other.v }
    virtual fn get(const self) -> i32 { return self.v }
}

fn reset() {
    copies = 0
    moves = 0
    drops = 0
    order = 0
}

fn copy_assign() -> i32 {
    var x = C(1)
    var y = C(2)
    var r = 0
    x = x
    if (copies == 0) && (drops == 0) && (x.v == 1) { r += 1 }    // nothing happened
    x = y
    if (copies == 1) && (drops == 1) && (x.v == 2) { r += 2 }    // the old x destroyed, y copied in
    if order == 12 { r += 4 }                                     // destroyed first, then copied
    return r
}

// From a temporary: the old m is destroyed, the temporary moved in, and the
// temporary destroyed at the end of the statement.
fn move_assign() -> i32 {
    var m = M(1)
    m = M(5)
    if (moves == 1) && (drops == 2) && (m.v == 5) { return 8 }
    return 0
}

fn generic_assign() -> i32 {
    var b = Box<i32>(1)
    var c = Box<i32>(2)
    var r = 0
    b = b
    if (copies == 0) && (drops == 0) && (b.v == 1) { r += 16 }
    b = c
    if (copies == 1) && (drops == 1) && (b.v == 2) { r += 32 }
    return r
}

fn trivial_assign() -> i32 {
    var a = T(1)
    var b = T(2)
    a = b
    if a.v == 2 { return 64 }
    return 0
}

fn main() -> i32 {
    var n = N(0)
    var p = Poly(0)
    var r = copy_assign()
    reset()
    r += move_assign()
    reset()
    r += generic_assign()
    r += trivial_assign()
    return r + n.v + p.get()            // 1 + 2 + 4 + 8 + 16 + 32 + 64 == 127
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// Each row as C++ is given it. Only a TU whose classes rebuild in place
// includes <new>: the region between the first two labels is builtin
// fmt/fmt_buf.k's preamble, which writes none; coro/generator.k writes
// Yield's.
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}fmt_buf.k
// CXX-NOT:   #include <new>
// CXX-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}generator.k
// CXX-NEXT:  #include <new>
// CXX:       Yield& operator=({{ ?}}::builtin::coro::generator::Yield<T>&& o) {
// CXX-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}derived_assign.k
// CXX-NEXT:  #include <new>
// CXX:       class C {
// CXX:       C& operator=(const{{ ?}}::derived_assign::C& o) {
// CXX-NEXT:  if{{ ?}}(this{{ ?}}!={{ ?}}&{{ ?}}o) {
// CXX-NEXT:  ~C();
// CXX-NEXT:  new{{ ?}}(static_cast<void{{ ?}}*>(this)) C(o);
// CXX:       class M {
// CXX:       M& operator=({{ ?}}::derived_assign::M&& o) {
// CXX:       new{{ ?}}(static_cast<void{{ ?}}*>(this)) M(static_cast<M&&>(o));
// CXX:       template<class X> class Box {
// CXX:       Box& operator=(const{{ ?}}::derived_assign::Box<X>& o) requires{{ ?}}(__is_destructible(X)) {
// CXX:       Box& operator=(const{{ ?}}::derived_assign::Box<X>&) requires{{ ?}}(!{{ ?}}(__is_destructible(X))) = delete;
// CXX:       class T {
// CXX:       T& operator=(const{{ ?}}::derived_assign::T&) = default;
// CXX:       class N {
// CXX:       N& operator=(const{{ ?}}::derived_assign::N&) = delete;
// CXX:       class Poly {
// CXX:       Poly& operator=(const{{ ?}}::derived_assign::Poly&) = delete;

// REQUIRES: clang, llvm-nm
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 127

// The same at -O2. Neither level calls an allocation function: clang emits
// the reserved placement form in place, so nothing has to define it.
// RUN: %kairo %s -c -O2 --cache-dir %t.d/o2
// RUN: %clangxx %t.d/o2/*.o %t.d/o2/builtin/*.o %t.d/o2/kairo/*.o -o %t.o2.exe
// RUN: %t.o2.exe; test $? -eq 127
// RUN: %nm %t.d/k/derived_assign.o %t.d/o2/derived_assign.o | { ! grep -q _Znw; }
