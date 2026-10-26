// A Kairo `fn` value across `#include "*.k"` (kcc, kcc_include_host.cc):
// the include stream defines `::__kairo_fn` once (InterfaceEmitter::
// have_fn_value), a returned closure is called from C++, and C++ passes a
// function and a captureless lambda where Kairo takes a `fn`. Also the
// header form (`--emit-headers`), which guards the helper with
// __KAIRO_FN_HELPERS.

pub fn make_scaler(k: i32) -> fn(i32) -> i32 {
    return fn (x: i32) -> i32 { return x * k }
}

pub fn apply(f: fn(i32) -> i32, x: i32) -> i32 { return f(x) }

pub class <T> Box {
    pub var v: T
    fn Box(self, v: T) { self.v = v }
    fn map_with(self, f: fn(T) -> T) -> T {
        var g = fn () -> T { return f(self.v) }
        return g()
    }
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, kcc
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s --check-prefix=HDR < %t.d/h/kcc_include.hh
// HDR: #ifndef __KAIRO_FN_HELPERS
// HDR: template<class S> class __kairo_fn;
// HDR: ::__kairo_fn<signed int(signed int)> make_scaler(signed int k);
// RUN: cd %S && %kcc -c kcc_include.k -o %t.d/lib.o
// RUN: cd %S && %kcc -c kcc_include_host.cc -o %t.d/host.o
// RUN: %kcc %t.d/host.o %t.d/lib.o -o %t.d/app && %t.d/app; test $? -eq 42
