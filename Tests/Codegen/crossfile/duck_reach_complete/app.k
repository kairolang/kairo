import user::*
import nodes::*

// O36b: classes a body needs complete though nothing typed names them by
// value: what a `<T: type>` instance's untyped chain walks through, a tuple
// record stored inline by an imported C++ template, and the argument of an
// imported C++ function template.
fn main() -> i32 {
    var tb = Table()
    var c = Ctx()
    c.g = unsafe (&tb)
    var t = Typer()
    t.sc = unsafe (&c)
    return duck_read(unsafe (&t)) + made()
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d --ffi-include %S/../../../../Lib/llvm-runtimes/llvm/include --ffi-include %S/../../../../build/llvm/include --cxx-define LLVM_DISABLE_ABI_BREAKING_CHECKS_ENFORCING=1
// RUN: %t.exe; test $? -eq 5
