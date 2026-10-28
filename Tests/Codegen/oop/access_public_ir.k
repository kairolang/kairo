// The C++ view of Kairo visibility: every member the user wrote is
// `public:`, whatever its `priv` / `prot` (and so is every base, whatever
// its edge says) -- C++ has no access level meaning "this module", and a
// `private:` member made clang refuse a free function in the class's own
// file. AccessCheck is the check. A C++ host including the module sees
// these members as public too. Only compiler-made members keep their
// access: a `where` group's candidates stay `private:`.

class Vault {
    var secret: i32 = 7
    prot var shared: i32 = 1
    priv fn peek(const self) -> i32 { return self.secret }
    fn pick(self, k: i32) -> i32 where k > 0 { return k }
    fn pick(self, k: i32) -> i32 { return 0 }
}

class Sealed derives priv Vault {
}

fn main() -> i32 {
    var v = Vault()
    return v.peek() + v.pick(1)
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(CXX) mode=cxx focus=Vault,Sealed -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.cxx.d
// RUN: { %kairo %s -c --cache-dir %t.cxx.d --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=CXX
// CXX: // ============== CODEGEN C++: {{.*}}oop/access_public_ir.k ==============
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class Vault;
// CXX-NEXT:     class Sealed;
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class Vault {
// CXX-NEXT:         public: signed int secret = 7;
// CXX-NEXT:         signed int shared = 1;
// CXX-NEXT:         signed int peek() const noexcept;
// CXX-NEXT:         signed int pick(signed int k) noexcept;
// CXX-NEXT:         private: signed int __kairo_where_pick_0(signed int k) noexcept;
// CXX-NEXT:         signed int __kairo_where_pick_1(signed int k) noexcept;
// CXX-NEXT:     };
// CXX-NEXT: }
// CXX: namespace {{[A-Za-z0-9_]+}} {
// CXX-NEXT:     class Sealed: public::{{[A-Za-z0-9_]+}}::Vault {
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
// CXX: int main() noexcept {
// CXX-NEXT:     ::{{[A-Za-z0-9_]+}}::Vault v = ::{{[A-Za-z0-9_]+}}::Vault();
// CXX-NEXT:     return(v.peek() + v.pick(1));
// CXX-NEXT: }
// END-GENERATED-CHECKS(CXX)
