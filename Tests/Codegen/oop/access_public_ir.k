// The C++ view of Kairo visibility: a `priv` member is `private:` and a
// `prot` one `protected:` (a class's variables private unless marked), and
// the class befriends the rest of its file -- here `main`, Plain and
// Sealed -- which is how C++ says Kairo's "this file". Bases stay public
// whatever the edge says (a private base would refuse the upcast Kairo
// allows).
// Compiler-made members keep their own access: a `where` group's
// candidates are `private:`. Codegen/oop/access_cxx_friends.k runs the
// same-file reaches; access_cxx_view.k pins one text across views.

class Vault {
    var secret: i32 = 7
    prot var shared: i32 = 1
    priv fn peek(const self) -> i32 { return self.secret }
    fn pick(self, k: i32) -> i32 where k > 0 { return k }
    fn pick(self, k: i32) -> i32 { return 0 }
    fn Vault(self) { }
}

// No constructor: a C++ aggregate, built by designated initializers, so
// its fields stay public whatever they say (CXXSpell::cxx_vis).
class Plain {
    var p: i32 = 1
}

class Sealed derives priv Vault {
}

fn main() -> i32 {
    var v = Vault()
    var q = Plain{ p: 2 }
    return v.peek() + v.pick(1) + q.p
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(CXX) mode=cxx focus=Vault,Sealed,Plain -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.cxx.d
// RUN: { %kairo %s -c --cache-dir %t.cxx.d --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=CXX
// CXX: // ============== CODEGEN C++: {{.*}}oop/access_public_ir.k ==============
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class Vault;
// CXX-NEXT:     class Plain;
// CXX-NEXT:     class Sealed;
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class Vault {
// CXX-NEXT:         signed int secret = 7;
// CXX-NEXT:         protected: signed int shared = 1;
// CXX-NEXT:         private: signed int peek() const noexcept;
// CXX-NEXT:         public: signed int pick(signed int k) noexcept;
// CXX-NEXT:         private: signed int __kairo_where_pick_0(signed int k) noexcept;
// CXX-NEXT:         signed int __kairo_where_pick_1(signed int k) noexcept;
// CXX-NEXT:         public: Vault() noexcept;
// CXX-NEXT:         friend::{{[A-Za-z0-9_]+}}::Plain;
// CXX-NEXT:         friend::{{[A-Za-z0-9_]+}}::Sealed;
// CXX-NEXT:         friend int::main() noexcept;
// CXX-NEXT:     };
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class Plain {
// CXX-NEXT:         public: signed int p = 1;
// CXX-NEXT:     };
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class Sealed: public::{{[A-Za-z0-9_]+}}::Vault {
// CXX-NEXT:         using::{{[A-Za-z0-9_]+}}::Vault::shared;
// CXX-NEXT:         using::{{[A-Za-z0-9_]+}}::Vault::pick;
// CXX-NEXT:         friend::{{[A-Za-z0-9_]+}}::Vault;
// CXX-NEXT:         friend::{{[A-Za-z0-9_]+}}::Plain;
// CXX-NEXT:         friend int::main() noexcept;
// CXX-NEXT:     };
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int Vault::peek() const noexcept {
// CXX-NEXT:         return this->secret;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int Vault::pick(signed int k) noexcept {
// CXX-NEXT:         if(k> 0) {
// CXX-NEXT:             return this->__kairo_where_pick_0(k);
// CXX-NEXT:         }
// CXX-NEXT:         return this->__kairo_where_pick_1(k);
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int Vault::__kairo_where_pick_0(signed int k) noexcept {
// CXX-NEXT:         return k;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     signed int Vault::__kairo_where_pick_1(signed int k) noexcept {
// CXX-NEXT:         return 0;
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     Vault::Vault() noexcept {
// CXX-NEXT:     }
// CXX-NEXT: }
// CXX: int main() noexcept {
// CXX-NEXT:     ::{{[A-Za-z0-9_]+}}::Vault v = ::{{[A-Za-z0-9_]+}}::Vault();
// CXX-NEXT:     ::{{[A-Za-z0-9_]+}}::Plain q = ::{{[A-Za-z0-9_]+}}::Plain {
// CXX-NEXT:         .p = 2
// CXX-NEXT:     };
// CXX-NEXT:     return((v.peek() + v.pick(1)) + q.p);
// CXX-NEXT: }
// END-GENERATED-CHECKS(CXX)
