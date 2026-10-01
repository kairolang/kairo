// receivers.k -- exit 9
struct In  { var w: i32; }
struct Foo { var v: i32; var inner: In; }
struct Bar { var f: Foo; }

extend Foo {
    fn get(const self) -> i32 { return self.v; }
    fn bump(self, x: i32) { self.v += x; }
    fn bump_ret(self, x: i32) -> i32 { self.v += x; return self.v; }
    fn twice(self) -> i32 { self.bump(1); return self.get(); }
}
extend In {
    fn win(self) -> i32 { self.w += 1; return self.w; }
}

fn make(v: i32) -> Foo { return Foo { v: v, inner: In { w: v * 10 } }; }

fn main() -> i32 {
    var a = Foo { v: 1, inner: In { w: 0 } };
    var b = Bar { f: Foo { v: 5, inner: In { w: 0 } } };
    var p: *Foo = &a;
    const c = Foo { v: 7, inner: In { w: 0 } };
    var r: i32 = 0;
    a.bump(3);                               if a.v == 4   { r += 1; }
    b.f.bump(1);                             if b.f.v == 6 { r += 1; }
    p->bump(1);                              if a.v == 5   { r += 1; }
    if a.twice() == 6                        { r += 1; }
    if make(10).bump_ret(5) == 15            { r += 1; }
    if make(9).get() == 9                    { r += 1; }
    if c.get() == 7                          { r += 1; }
    if make(2).inner.win() == 21             { r += 1; }
    if make(3).bump_ret(make(4).get()) == 7  { r += 1; }
    return r;
}

// --- lit wiring -----------------------------------------------------------
// At the BOTTOM: the LOW block pins line:col.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// The receiver forms: an lvalue by address, a field path by address, a
// pointer as is, `self` passed on as the pointer it is, and a prvalue
// receiver materialized for the full-expression. The sequenced call binds
// the receiver's VALUE (a `Foo`, never a `Foo*`, whose temporary would end
// at its own `;`).
// CXX: struct __kairo_ext_Foo {
// CXX: __kairo_ext_Foo::twice( ::receivers::Foo * self) {
// CXX-NEXT: __kairo_ext_Foo::bump(self, 1);
// CXX-NEXT: __kairo_ext_Foo::get(self);
// CXX: int main() {
// CXX: __kairo_ext_Foo::bump((& a), 3);
// CXX: __kairo_ext_Foo::bump((& b.f), 1);
// CXX: __kairo_ext_Foo::bump(p, 1);
// CXX: __kairo_ext_Foo::bump_ret( ::__kairo_tmp( ::receivers::make(10)), 5)
// CXX: __kairo_ext_Foo::get( ::__kairo_tmp( ::receivers::make(9)))
// CXX: __kairo_ext_In::win( ::__kairo_tmp( ::receivers::make(2).inner))
// CXX: ::receivers::Foo __kairo_arg{{[0-9]+}} = ::receivers::make(3);
// CXX-NOT: Foo * __kairo_arg
// CXX: __kairo_ext_Foo::bump_ret((& __kairo_arg{{[0-9]+}}), __kairo_arg{{[0-9]+}});

// After Lower, every call to an extension member is a plain call: its callee
// is the member's name, never a chain. One `[materialized]` per prvalue
// receiver: make(10), make(9), make(2).inner, and make(4) inside the
// sequenced call (make(3)'s became a bound value there).
// RUN: { %kairo %s --type-check-only --print-lowered 2>&1 || true; } | %FileCheck %s --check-prefix=LOW
// LOW: SEMA fid 0: {{.*}}receivers.k
// LOW: CallExpr {{ *}}@ 10:29 {{.*}}
// LOW-NEXT: NamedIdentExpr {{ *}}@ 10:33
// LOW: CallExpr {{ *}}@ 10:50 {{.*}}
// LOW-NEXT: NamedIdentExpr {{ *}}@ 10:54
// LOW: CallExpr {{ *}}@ 24:5 {{.*}}
// LOW-NEXT: NamedIdentExpr {{ *}}@ 24:6
// LOW: CallExpr {{ *}}@ 25:5 {{.*}}
// LOW-NEXT: NamedIdentExpr {{ *}}@ 25:8
// LOW: CallExpr {{ *}}@ 26:5 {{.*}}
// LOW-NEXT: NamedIdentExpr {{ *}}@ 26:6
// LOW: CallExpr {{ *}}@ 27:8 {{.*}}
// LOW-NEXT: NamedIdentExpr {{ *}}@ 27:9
// LOW: CallExpr {{ *}}@ 28:8 {{.*}}
// LOW-NEXT: NamedIdentExpr {{ *}}@ 28:16
// LOW: CallExpr {{ *}}@ 29:8 {{.*}}
// LOW-NEXT: NamedIdentExpr {{ *}}@ 29:15
// LOW: CallExpr {{ *}}@ 30:8 {{.*}}
// LOW-NEXT: NamedIdentExpr {{ *}}@ 30:9
// LOW: CallExpr {{ *}}@ 31:8 {{.*}}
// LOW-NEXT: NamedIdentExpr {{ *}}@ 31:21
// LOW: CallExpr {{ *}}@ 32:8 {{ *}}: i32
// LOW-NEXT: NamedIdentExpr {{ *}}@ 32:15
// RUN: { %kairo %s --type-check-only --print-lowered 2>&1 || true; } | grep -c "\[materialized\]" | %FileCheck %s --check-prefix=MAT
// MAT: {{^4$}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 9
