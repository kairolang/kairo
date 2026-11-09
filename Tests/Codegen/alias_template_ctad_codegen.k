// A generic alias applied WITHOUT arguments (`BoxA(x)` over `template
// <class T> using BoxA = Box<T>`, the self-host's `LockGuard(self._mu)`) is
// deduced by clang. The local's type is the alias's pattern `Box<T>`, whose
// T is the alias's and not in scope in the emitted body: spelling it gave
// "use of undeclared identifier 'T'". The template's name alone is emitted
// and clang deduces the arguments.

ffi "c++" import "alias_template_ctad_codegen.h"

class C {
    priv var m: Mu;
    fn f(self) -> i32 {
        var g = BoxA(self.m)
        return 4
    }
}

fn main() -> i32 {
    var c = C()
    return c.f()
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 4
