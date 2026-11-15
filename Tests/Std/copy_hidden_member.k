// std::copy of a class whose `copy` method is not public: a member that is
// not `pub` implements `CopiesItself` only for an `impl` its own file
// declares, but the emitted C++ still finds it, so Kairo cannot treat it as
// absent and pick the copy constructor. The call is an error naming the
// member, with a fix-it making it public, instead of "ambiguous".

import std

class Unmarked {
    pub var n: i32
    pub fn Unmarked(self, n: i32) {
        self.n = n
    }

    fn copy(const self) -> Self {
        return Unmarked(self.n)
    }
}

class Marked {
    pub var n: i32
    pub fn Marked(self, n: i32) {
        self.n = n
    }

    priv fn copy(const self) -> Self {
        return Marked(self.n)
    }
}

fn main() -> i32 {
    var u = Unmarked(1)
    var m = Marked(2)
    var a = std::copy(u)
    var b = std::copy(m)
    return a.n + b.n - 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: copy_hidden_member.k:34:13: error [SC162E]: cannot choose an overload here: 'Unmarked' has a 'copy' that would implement 'CopiesItself', but it is not public
// CHECK-NEXT: fix-it:"{{.*}}copy_hidden_member.k":{15:5-15:5}:"pub "
// CHECK-NEXT: utility.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: the overloads are told apart by this test
// CHECK-NEXT: copy_hidden_member.k:15:8: note [I900N]: 'copy' is declared here: a member that is not public implements an interface only for an 'impl' declared in its own file
// CHECK: copy_hidden_member.k:35:13: error [SC162E]: cannot choose an overload here: 'Marked' has a 'copy' that would implement 'CopiesItself', but it is not public
// CHECK-NEXT: fix-it:"{{.*}}copy_hidden_member.k":{26:5-26:9}:"pub"
// CHECK: copy_hidden_member.k:26:13: note [I900N]: 'copy' is declared here
