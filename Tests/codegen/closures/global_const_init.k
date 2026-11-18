// A namespace-scope `fn` value initialized from a named function, or from
// a closure that captures nothing, is constant-initialized: the global's
// initializer in the object is the function pointer itself, not a zero
// filled in by a constructor call at startup. A constructor call there is
// a static-init order hazard (another TU's initializer calling through the
// value would find it empty) and startup work for nothing. The destructor
// is a runtime one (a `fn` value may own a heap lambda), so C++ still
// registers it at exit; that is all the startup code may do with them.

fn twice(v: i32) -> i32 { return v * 2 }

var handler: fn(i32) -> i32 = twice
var bump = fn (v: i32) -> i32 { return v + 1 }

fn main() -> i32 {
    // 6 + 2 - 8
    return handler(3) + bump(1) - 8
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.ir
// RUN: %kairo %s --emit=llvm-ir -O0 --cache-dir %t.ir
// RUN: %FileCheck %s --check-prefix=IR < %t.ir/global_const_init.ll
// IR-DAG: @{{.*}}7handlerE = global %class.__kairo_fn { ptr @{{.*}}5twiceEi, ptr null, ptr null }
// IR-DAG: @{{.*}}4bumpE = global %class.__kairo_fn { ptr @{{.*}}, ptr null, ptr null }
// No constructor of the value runs on either at startup.
// RUN: not grep -E 'call .*__kairo_fn.*C[12]E.*(7handlerE|4bumpE)' %t.ir/global_const_init.ll

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
