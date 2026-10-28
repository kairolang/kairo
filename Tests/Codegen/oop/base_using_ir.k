// The derived class's definition carries `using Base::name;` for every
// method name it shares with a base (InterfaceEmitter::_base_usings): Kairo
// merges a base's overloads with the derived class's, C++ would hide them,
// and the using-declaration makes C++'s overload set Kairo's. Not for a
// constructor, the destructor, or a name only one side has; through a
// generic base by its instance; once per base that answers the name.

class A {
    virtual fn k(self) -> i32 { return 1 }
    fn f(self, x: i32) -> i32 { return 1 }
    fn only_base(self) -> i32 { return 1 }
    fn A(self) { }
    virtual fn op delete(self) { }
}

class D derives A {
    override fn k(self) -> i32 { return 2 }
    fn f(self, x: f64) -> i32 { return 2 }
    fn only_derived(self) -> i32 { return 2 }
    fn D(self) { }
    override fn op delete(self) { }
}

class <T> G {
    fn g(self, t: T) -> i32 { return 1 }
}

class GD derives G<i32> {
    fn g(self, t: f64) -> i32 { return 2 }
}

class L { fn m(self) -> i32 { return 1 } }
class R { fn m(self) -> i32 { return 2 } }
class LR derives L, R {
    fn m(self) -> i32 { return 3 }
}

fn main() -> i32 {
    var d = D()
    var g = GD()
    var lr = LR()
    var i: i32 = 1
    return d.k() + d.f(i) + g.g(i) + lr.m()
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(CXX) mode=cxx focus=A,D,G,GD,L,R,LR -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.cxx.d
// RUN: { %kairo %s -c --cache-dir %t.cxx.d --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=CXX
// CXX: // ============== CODEGEN C++: {{.*}}oop/base_using_ir.k ==============
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class A;
// CXX-NEXT:     class D;
// CXX-NEXT:     template<class T> class G;
// CXX-NEXT:     class GD;
// CXX-NEXT:     class L;
// CXX-NEXT:     class R;
// CXX-NEXT:     class LR;
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class A {
// CXX-NEXT:         public: virtual signed int k() noexcept;
// CXX-NEXT:         signed int f(signed int x) noexcept;
// CXX-NEXT:         signed int only_base() noexcept;
// CXX-NEXT:         A() noexcept;
// CXX-NEXT:         virtual ~A() noexcept;
// CXX-NEXT:     };
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class D: public::{{[A-Za-z0-9_]+}}::A {
// CXX-NEXT:         public: virtual signed int k() noexcept override;
// CXX-NEXT:         signed int f(double x) noexcept;
// CXX-NEXT:         signed int only_derived() noexcept;
// CXX-NEXT:         D() noexcept;
// CXX-NEXT:         virtual ~D() noexcept override;
// CXX-NEXT:         using::{{[A-Za-z0-9_]+}}::A::k;
// CXX-NEXT:         using::{{[A-Za-z0-9_]+}}::A::f;
// CXX-NEXT:     };
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     template<class T> class G {
// CXX-NEXT:         public: signed int g(T t) noexcept;
// CXX-NEXT:     };
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class GD: public::{{[A-Za-z0-9_]+}}::G<signed int> {
// CXX-NEXT:         public: signed int g(double t) noexcept;
// CXX-NEXT:         using::{{[A-Za-z0-9_]+}}::G<signed int>::g;
// CXX-NEXT:     };
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class L {
// CXX-NEXT:         public: signed int m() noexcept;
// CXX-NEXT:     };
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class R {
// CXX-NEXT:         public: signed int m() noexcept;
// CXX-NEXT:     };
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class LR: public::{{[A-Za-z0-9_]+}}::L, public::{{[A-Za-z0-9_]+}}::R {
// CXX-NEXT:         public: signed int m() noexcept;
// CXX-NEXT:         using::{{[A-Za-z0-9_]+}}::L::m;
// CXX-NEXT:         using::{{[A-Za-z0-9_]+}}::R::m;
// CXX-NEXT:     };
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int A::k() noexcept {
// CXX-NEXT:         return 1;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int A::f(signed int x) noexcept {
// CXX-NEXT:         return 1;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int A::only_base() noexcept {
// CXX-NEXT:         return 1;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     A::A() noexcept {
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     A::~A() noexcept {
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int D::k() noexcept {
// CXX-NEXT:         return 2;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int D::f(double x) noexcept {
// CXX-NEXT:         return 2;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int D::only_derived() noexcept {
// CXX-NEXT:         return 2;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     D::D() noexcept {
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     D::~D() noexcept {
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     template<class T> signed int G<T>::g(T t) noexcept {
// CXX-NEXT:         return 1;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int GD::g(double t) noexcept {
// CXX-NEXT:         return 2;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int L::m() noexcept {
// CXX-NEXT:         return 1;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int R::m() noexcept {
// CXX-NEXT:         return 2;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int LR::m() noexcept {
// CXX-NEXT:         return 3;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: int main() noexcept {
// CXX-NEXT:     ::{{[A-Za-z0-9_]+}}::D d = ::{{[A-Za-z0-9_]+}}::D();
// CXX-NEXT:     ::{{[A-Za-z0-9_]+}}::GD g = ::{{[A-Za-z0-9_]+}}::GD();
// CXX-NEXT:     ::{{[A-Za-z0-9_]+}}::LR lr = ::{{[A-Za-z0-9_]+}}::LR();
// CXX-NEXT:     signed int i = 1;
// CXX-NEXT:     return(((d.k() + d.f(i)) + g.g(i)) + lr.m());
// CXX-NEXT: }
// CXX: template class::{{[A-Za-z0-9_]+}}::G<signed int>;
// END-GENERATED-CHECKS(CXX)
