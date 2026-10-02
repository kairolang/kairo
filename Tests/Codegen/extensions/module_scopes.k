// module_scopes.k -- exit 12
class Acct {
    priv var bal: i32;
    fn Acct(self, b: i32) { self.bal = b; }
}

extend Acct { fn peek(const self) -> i32 { return self.bal; } }

module Geo {
    extend Acct { fn twice(const self) -> i32 { return self.bal * 2; } }
}

fn main() -> i32 {
    var a = Acct(4);
    return a.peek() + a.twice();
}

// --- lit wiring -----------------------------------------------------------
// Two same-file scopes for one class, in two namespaces: both read a priv
// field, so the class befriends both -- one friend line each.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: class Acct {
// CXX-DAG: friend struct::module_scopes::__kairo_ext_Acct;
// CXX-DAG: friend struct::module_scopes::Geo::__kairo_ext_module_scopes__Acct;
// CXX: int main() {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 12
