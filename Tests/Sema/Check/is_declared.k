// `__builtin_is_declared<P>()`: whether the path P names a declaration in
// the file. A path that names nothing is `false`, never an error. It folds
// before names are resolved, so it decides a file-scope `eval if`, an
// `eval` constant and a function-body condition alike. Kairo paths here;
// C++ paths are in Tests/Sema/FFI/is_declared_cxx.k.

class Foo {
    pub class Inner { }
    pub fn method(self) { }
}

module m {
    pub fn f() { }
    pub module deep { pub var x: i32 = 0 }
}

type Alias = Foo
enum Color { Red, Green }

eval if __builtin_is_declared<Foo>() { fn a() -> i32 { return 1 } } else { fn a() -> i32 { return 100 } }
eval if __builtin_is_declared<Nope>() { fn b() -> i32 { return 100 } } else { fn b() -> i32 { return 2 } }
eval if __builtin_is_declared<Foo::Inner>() && __builtin_is_declared<m::f>() && !__builtin_is_declared<m::g>() {
    fn c() -> i32 { return 3 }
} else {
    fn c() -> i32 { return 100 }
}

// A name only an untaken branch declares is not declared.
eval if false { class Ghost { } }
eval HAS_GHOST = __builtin_is_declared<Ghost>()

eval DEEP  = __builtin_is_declared<m::deep::x>()
eval MISS  = __builtin_is_declared<cxx::std::string>()   // no C++ header here
eval PRIM  = __builtin_is_declared<i32>()
eval ALIAS = __builtin_is_declared<Alias>()
eval METH  = __builtin_is_declared<Foo::method>()
eval ENUMV = __builtin_is_declared<Color::Red>()
eval FN    = __builtin_is_declared<a>()

fn main() -> i32 {
    var t = 0
    if __builtin_is_declared<no::such::path>() { t += 100 }
    if __builtin_is_declared<m>() { t += 4 }
    eval if __builtin_is_declared<main>() { t += 5 }
    if HAS_GHOST || MISS { t += 100 }
    if DEEP && PRIM && ALIAS && METH && ENUMV && FN { t += 6 }
    return a() + b() + c() + t - 21
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
// RUN: %kairo %s --print-sema | %FileCheck %s --check-prefix=SEMA
// Each call is its answer before names are resolved:
// SEMA-NOT: __builtin_is_declared
