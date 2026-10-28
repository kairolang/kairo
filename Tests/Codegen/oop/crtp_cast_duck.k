// The CRTP downcast under a duck parameter: in `class <T: type> Counter`
// nothing Kairo-side relates T to Counter<T>, but `: type` is the
// C++-checked regime (MONO.md D1), so `&self as *T` is written as C++'s
// static_cast and clang checks each instance. An instance whose T does not
// derive the mixin is clang's error there, never a reinterpret.
//
// This is Compiler/'s mixin shape (`fn dyn(self) -> *D`, `self.dyn()->m()`)
// with several mixins on one class, so all but the first sit at a nonzero
// offset. Through `as unsafe *T` (a reinterpret_cast) the same program read
// the wrong subobject and exited 3; the static_cast adjusts the pointer.

class Base {
    pub var b: i32 = 100
}

class <T: type> Counter {
    pub var hits: i32 = 0
    fn dyn(self) -> *T { return &self as *T }
    fn bump(self) -> i32 {
        self.hits += 1
        return self.dyn()->weight()
    }
}

class <T: type> Tagged {
    enum Kind { A, B }
    pub var tag: i32 = 3
    fn cdyn(const self) -> *const T { return &self as *const T }
    fn tagged(const self) -> i32 { return self.tag * self.cdyn()->weight() + self.cdyn()->b }
}

class Node derives Base, Counter<Node>, Tagged<Node> {
    pub var w: i32 = 2
    fn weight(const self) -> i32 { return self.w }
}

fn main() -> i32 {
    var n = Node()
    var r = n.bump()          // 2
    r += n.tagged()           // 3 * 2 + 100
    r += n.hits               // 1
    return r                  // 109
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -fduck-generics --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s -fduck-generics --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: static_cast<T *>(
// CXX: static_cast<const T *>(
// CXX-NOT: reinterpret_cast<{{(const )?}}T *>

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 109
