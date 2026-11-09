// A member of a concrete C++ instance (`out.push_back(x)` on a
// `vector<*A>`) whose ARGUMENT is dependent (`cur as *A`, `cur` of a
// `<T: type>` type) is left to its overload set by Sema. EmitIR used to ICE
// "unpromoted callee step"; it now goes out as written and clang picks the
// overload in each instance.

ffi "c++" import "vector";

class A {
    pub var n: i32;
    fn first(self) -> unsafe *A { return unsafe (&self); }
}

class B {
    priv static fn <T: type> ring(d: unsafe *T, @inout out: cxx::std::vector<unsafe *A>) {
        var cur = d->first();
        out.push_back(unsafe (cur as unsafe *A));
    }
}

fn main() -> i32 {
    var v: cxx::std::vector<unsafe *A>;
    var a = A{n: 1};
    B::ring<A>(unsafe (&a), &v);
    return v.size() as i32;   // 1
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 1
