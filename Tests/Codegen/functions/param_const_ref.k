// P331: a by-value parameter of a COPY record the body never mutates is
// passed as `const T&`, and SC001W says to write the `const` (with the
// fix-it). A parameter the body mutates, moves out, takes the address of or
// uses in a closure keeps its by-value copy, and so does every parameter the
// inference does not consider: scalars, trivially copyable records, MOVE
// records, `self`, an explicit `const`, an override's. A `fn` value of an
// inferred function goes through an adapter with the type's own signature.

class Box {
    var v: string = ""
    fn get(const self) -> usize { return self.v.length() }
    fn put(self, s: string) { self.v = s }          // s: const&, the field copies it
}

struct Pt { var x: i32 = 0; var y: i32 = 0 }        // trivially copyable: by value

class Handle {
    var id: i32 = 0
    fn Handle(self) { }
    @move fn Handle(self, other: Self) { self.id = other.id }
}

class Base {
    virtual fn name(self, s: string) -> usize { return s.length() }
}
class Derived derives Base {
    override fn name(self, s: string) -> usize { return s.length() + 1 }
}

fn read(s: string) -> usize { return s.length() }
fn forward(s: string) -> usize { return read(s) }
fn copy_local(s: string) -> usize { var t = s; t += "!"; return t.length() }
fn compare(a: string, b: string) -> bool { return a == b }
fn written(const s: string) -> usize { return s.length() }

fn assigns(s: string) -> usize { s = "x"; return s.length() }
fn appends(s: string) -> usize { s += "x"; return s.length() }
fn returns(s: string) -> string { return s }
fn address(s: string) -> usize { var *p = &s; return p->length() }
fn in_closure(s: string) -> usize { var f = fn () -> usize { return s.length() }; return f() }
fn mut_method(b: Box) -> usize { b.put("q"); return b.get() }
fn const_method(b: Box) -> usize { return b.get() }

fn scalar(n: i64) -> i64 { return n + 1 }
fn point(p: Pt) -> i32 { return p.x + p.y }
fn handle(h: Handle) -> i32 { return h.id }

fn apply(f: fn(string) -> usize, s: string) -> usize { return f(s) }

fn main() -> i32 {
    var s: string = "hello"
    var r: usize = 0
    r += read(s) + forward(s) + copy_local(s) + written(s)
    if compare(s, "hello") { r += 1 }
    r += assigns(s) + appends(s) + returns(s).length() + address(s) + in_closure(s)
    var b = Box()
    b.put(s)
    r += const_method(b) + mut_method(b)
    var d = Derived()
    var bp: *Base = &d
    r += bp->name(s)
    var g = read
    r += g(s) + apply(read, s) + apply(forward, s) + apply(written, s)
    if s != "hello" { return 99 }
    // 5 5 6 5 +1, 1 6 5 5 5, 5 1, 6, 5 5 5 5 (a written const goes through the adapter too)
    var h = Handle()
    r += ool()
    return (r as i64 + scalar(1) + (point(Pt{x: 1, y: 2}) + handle(h)) as i64) as i32
}

// An out-of-line definition: the class body's declaration and the
// definition are two links, both stamped, so C++ sees one signature.
class Ool {
    var n: usize = 0
    fn m(self, s: string) -> usize
}
fn Ool::m(self, s: string) -> usize { self.n += s.length(); return self.n }
fn ool() -> usize { var o = Ool(); var s: string = "abc"; return o.m(s) }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:12:18: warning [SC001W]: parameter 's' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{12:18-12:18}:"const "
// DIAG: {{.*}}:30:9: warning [SC001W]: parameter 's' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{30:9-30:9}:"const "
// DIAG: {{.*}}:31:12: warning [SC001W]: parameter 's' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{31:12-31:12}:"const "
// DIAG: {{.*}}:32:15: warning [SC001W]: parameter 's' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{32:15-32:15}:"const "
// DIAG: {{.*}}:33:12: warning [SC001W]: parameter 'a' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{33:12-33:12}:"const "
// DIAG: {{.*}}:33:23: warning [SC001W]: parameter 'b' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{33:23-33:23}:"const "
// DIAG: {{.*}}:42:17: warning [SC001W]: parameter 'b' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{42:17-42:17}:"const "
// DIAG: {{.*}}:48:34: warning [SC001W]: parameter 's' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{48:34-48:34}:"const "
// DIAG: {{.*}}:77:17: warning [SC001W]: parameter 's' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{77:17-77:17}:"const "
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 84
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)

// The signatures as C++ declares them (the definitions repeat them): a
// const reference for each warned parameter, the value for the rest. A `fn`
// value of an inferred function is the adapter with the type's own by-value
// parameter.
// RUN: rm -rf %t.cxx.d
// RUN: %kairo %s --print-ir -o %t.cxx.exe --cache-dir %t.cxx.d > %t.cxx.ir
// RUN: %FileCheck %s --check-prefix=CXX --input-file=%t.cxx.ir
// CXX-DAG: void put(const::builtin::string::string & s) noexcept;
// CXX-DAG: decltype(sizeof(0)) m(const::builtin::string::string & s) noexcept;
// CXX-DAG: decltype(sizeof(0)) Ool::m(const::builtin::string::string & s) noexcept {
// CXX-DAG: decltype(sizeof(0)) read(const::builtin::string::string & s) noexcept;
// CXX-DAG: decltype(sizeof(0)) forward(const::builtin::string::string & s) noexcept;
// CXX-DAG: decltype(sizeof(0)) copy_local(const::builtin::string::string & s) noexcept;
// CXX-DAG: bool compare(const::builtin::string::string & a, const::builtin::string::string & b) noexcept;
// CXX-DAG: decltype(sizeof(0)) written(const::builtin::string::string & s) noexcept;
// CXX-DAG: decltype(sizeof(0)) assigns( ::builtin::string::string s) noexcept;
// CXX-DAG: decltype(sizeof(0)) appends( ::builtin::string::string s) noexcept;
// CXX-DAG: ::builtin::string::string returns( ::builtin::string::string s) noexcept;
// CXX-DAG: decltype(sizeof(0)) address( ::builtin::string::string s) noexcept;
// CXX-DAG: decltype(sizeof(0)) in_closure( ::builtin::string::string s) noexcept;
// CXX-DAG: decltype(sizeof(0)) mut_method( ::param_const_ref::Box b) noexcept;
// CXX-DAG: decltype(sizeof(0)) const_method(const::param_const_ref::Box & b) noexcept;
// CXX-DAG: signed long scalar(signed long n) noexcept;
// CXX-DAG: signed int point( ::param_const_ref::Pt p) noexcept;
// CXX-DAG: signed int handle( ::param_const_ref::Handle h) noexcept;
// CXX-DAG: decltype(sizeof(0)) apply( ::__kairo_fn<decltype(sizeof(0))( ::builtin::string::string)> f, const::builtin::string::string & s) noexcept;
// CXX-DAG: virtual decltype(sizeof(0)) name( ::builtin::string::string s) noexcept
// CXX-DAG: ::__kairo_fn<decltype(sizeof(0))( ::builtin::string::string)> g = static_cast< ::__kairo_fn<decltype(sizeof(0))( ::builtin::string::string)>>( ::__kairo_fn<decltype(sizeof(0))( ::builtin::string::string)>(+[]( ::builtin::string::string __kairo_a0) noexcept->decltype(sizeof(0)) {
