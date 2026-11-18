// The forms `__builtin_is_declared` refuses. The operand is one path of
// plain names (a template is named bare); and the condition of an
// `eval if` in a type's body cannot ask it, because a type has one member
// list in every file.

fn x() -> bool { return __builtin_is_declared<cxx::std::vector<i32>>() }
fn y() -> bool { return __builtin_is_declared<*i32>() }
fn z() -> bool { return __builtin_is_declared<a>(1) }
fn w() -> bool { return __builtin_is_declared<a, b>() }

class K {
    eval if __builtin_is_declared<cxx::std::string>() {
        fn m(self) -> i32 { return 1 }
    }
}

struct S { var v: i32 }

extend S requires !__builtin_is_declared<Gone>() {
    fn n(const self) -> i32 { return 1 }
}

interface I { fn n(const self) -> i32 }

extend S impl I requires __builtin_is_declared<S>() {
    fn n(const self) -> i32 { return 1 }
}

// A miss is an answer, not an error.
fn ok() -> bool { return __builtin_is_declared<cxx::std::string>() || __builtin_is_declared<nothing::here>() }

// The name is the compiler's: the call is recognised by its spelling.
fn __builtin_is_declared() -> bool { return true }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: is_declared_errors.k:6:25: error [SC341E]: '__builtin_is_declared' is written '__builtin_is_declared<path>()': a template is named without its arguments: the question is whether the name is declared
// CHECK: is_declared_errors.k:7:25: error [SC341E]: '__builtin_is_declared' is written '__builtin_is_declared<path>()': its operand is a path of names, such as 'a::b::C', not a type built from one
// CHECK: is_declared_errors.k:8:25: error [SC341E]: '__builtin_is_declared' is written '__builtin_is_declared<path>()': it takes one path between '<' and '>' and no arguments
// CHECK: is_declared_errors.k:9:25: error [SC341E]: {{.*}}it takes one path between '<' and '>' and no arguments
// CHECK: is_declared_errors.k:12:13: error [SC342E]: '__builtin_is_declared' cannot be used here: the members of a type are the same in every file, so they cannot depend on what a file declares; put them in an extension
// CHECK: is_declared_errors.k:19:19: error [SC342E]: '__builtin_is_declared' cannot be used here: in an extension's 'requires' clause it is a whole operand of '&&', so the extension's body can rely on the path being declared
// CHECK: is_declared_errors.k:25:26: error [SC342E]: '__builtin_is_declared' cannot be used here: an extension that implements an interface cannot depend on what a file declares yet; conformance is one fact for the whole build
// CHECK: is_declared_errors.k:33:1: error [SC341E]: '__builtin_is_declared' is the compiler's query and cannot be declared
