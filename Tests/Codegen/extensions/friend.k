// friend.k -- exit 42
class Acct {
    priv var bal: i32;
    fn Acct(self, b: i32) { self.bal = b; }
}
class <T> Vault {
    priv var item: T;
    fn Vault(self, x: T) { self.item = x; }
}

extend Acct { fn peek(const self) -> i32 { return self.bal; } }
extend <T> Vault<T> { fn open(const self) -> T { return self.item; } }

fn main() -> i32 {
    var a = Acct(40);
    var v = Vault<i64>(2);
    return a.peek() + (v.open() as i32);
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// One friend struct per record, generic or not; a member never befriends
// itself line by line. Constructors are pub by default in a class
// (classes.md), so `Acct(40)` is callable.
// CXX: class Acct {
// CXX: friend struct::friend_::__kairo_ext_Acct;
// CXX: class Vault {
// CXX: friend struct::friend_::__kairo_ext_Vault;
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=NOFR
// NOFR-NOT: {{^ *}}friend {{[^s]}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 42
