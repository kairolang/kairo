ffi "c++" import "ffi_ref_return.h"

interface Getter { fn get(self) -> ffi::ref<i32>; }
class Holder { var f: ffi::ref<i32>; fn m(self) -> ffi::ref<i32> { return self.f } }
type Alias = ffi::ref<i32>
fn kairo_fn(@inout a: i32) -> ffi::ref<i32> { return a }
fn param(x: ffi::ref<i32>) { }
fn in_vector() -> [ffi::ref<i32>] { return [] }
fn in_nullable() -> ffi::ref<i32>? { return null }
fn in_fn_ptr(f: fn() -> ffi::mref<i32>) { }
fn <T> generic(@inout a: T) -> ffi::ref<T> { return a }
fn nested() -> ffi::ref<ffi::ref<i32>> { return 0 }
class Plain { fn own(self) -> ffi::ref<i32> { return 0 } }
extend Widget { fn ext(self) -> ffi::ref<i32> { return self.items[0] } }

fn main() -> i32 {
    var n: i32 = 0
    var local: ffi::ref<i32> = n
    var c = fn() -> ffi::ref<i32> { return n }
    var g: Vector<ffi::ref<i32>>
    return 0
}

// --- lit wiring -----------------------------------------------------------
// `ffi::ref<T>` / `ffi::mref<T>` anywhere but the whole return type of a
// definition of a C++-declared function or an override of a C++ virtual:
// one SC293E each, and the misplaced node reads as its referee afterwards,
// so nothing cascades. Red on a compiler without `ffi::ref` (S053E).
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG-DAG: ffi_ref_return_positions.k:3:36: error [SC293E]: 'get' cannot return 'ffi::ref' / 'ffi::mref': it is declared in Kairo, not C++
// DIAG-DAG: ffi_ref_return_positions.k:4:23: error [SC293E]: 'ffi::ref' and 'ffi::mref' are not types: they may only be the whole return type of a definition of a function C++ declares returning a reference
// DIAG-DAG: ffi_ref_return_positions.k:4:52: error [SC293E]: 'm' cannot return 'ffi::ref' / 'ffi::mref': it overrides no C++ virtual method
// DIAG-DAG: ffi_ref_return_positions.k:5:14: error [SC293E]: 'ffi::ref' and 'ffi::mref' are not types
// DIAG-DAG: ffi_ref_return_positions.k:6:31: error [SC293E]: 'kairo_fn' cannot return 'ffi::ref' / 'ffi::mref': it is declared in Kairo, not C++
// DIAG-DAG: ffi_ref_return_positions.k:7:13: error [SC293E]: 'ffi::ref' and 'ffi::mref' are not types
// DIAG-DAG: ffi_ref_return_positions.k:8:20: error [SC293E]: 'ffi::ref' and 'ffi::mref' are not types
// DIAG-DAG: ffi_ref_return_positions.k:9:21: error [SC293E]: 'ffi::ref' and 'ffi::mref' are not types
// DIAG-DAG: ffi_ref_return_positions.k:10:25: error [SC293E]: 'ffi::ref' and 'ffi::mref' are not types
// DIAG-DAG: ffi_ref_return_positions.k:11:32: error [SC293E]: 'generic' cannot return 'ffi::ref' / 'ffi::mref': a generic definition cannot spell a C++ reference return yet
// DIAG-DAG: ffi_ref_return_positions.k:12:16: error [SC293E]: 'nested' cannot return 'ffi::ref' / 'ffi::mref': it is declared in Kairo, not C++
// DIAG-DAG: ffi_ref_return_positions.k:12:25: error [SC293E]: 'ffi::ref' and 'ffi::mref' are not types
// DIAG-DAG: ffi_ref_return_positions.k:13:31: error [SC293E]: 'own' cannot return 'ffi::ref' / 'ffi::mref': it overrides no C++ virtual method
// DIAG-DAG: ffi_ref_return_positions.k:14:33: error [SC293E]: 'ext' cannot return 'ffi::ref' / 'ffi::mref': it is declared in Kairo, not C++
// DIAG-DAG: ffi_ref_return_positions.k:18:16: error [SC293E]: 'ffi::ref' and 'ffi::mref' are not types
// DIAG-DAG: ffi_ref_return_positions.k:19:21: error [SC293E]: 'ffi::ref' and 'ffi::mref' are not types
// DIAG-DAG: ffi_ref_return_positions.k:20:19: error [SC293E]: 'ffi::ref' and 'ffi::mref' are not types
