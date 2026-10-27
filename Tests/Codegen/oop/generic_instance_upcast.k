// A generic class deriving a generic base with its own parameter
// (`class <T> Const derives Source<T>`, classes.md, Generic Classes): an
// instance upcasts to the matching base instance and dispatches through it.
//
// An instance's bases are its pattern's list read through its arguments
// (MONO.md G4): `Const<i32>` derives `Source<i32>`, and `Leaf<i32>` of
// `derives Mid<*T>` derives `Mid<*i32>` and through it `Source<*i32>`.
// The mismatched instances stay unrelated: Tests/Sema/Types/
// instance_base_substitution.k.

class <T> Source {
    virtual fn get(self) -> i32 { return 0 }
}

class <T> Const derives Source<T> {
    var v: i32
    fn Const(self, v: i32) { self.v = v }
    override fn get(self) -> i32 { return self.v }
}

class <T> Mid derives Source<T> {
    override fn get(self) -> i32 { return 1 }
}

class <T> Leaf derives Mid<*T> {
    override fn get(self) -> i32 { return 2 }
}

fn main() -> i32 {
    var k = Const<i32>(41)
    var s: *Source<i32> = &k
    var l = Leaf<i32>()
    var m: *Mid<*i32>    = &l
    var t: *Source<*i32> = m
    var u: *Source<*i32> = &l
    return s->get() + t->get() + u->get()      // 41 + 2 + 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 45
