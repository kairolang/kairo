// A builtin allocator named only as a generic argument: this TU never
// names a member of System, so nothing but the instance's bound admits it,
// and C++ checks Allocator_c<System> -- whose witness members are
// `requires`-guarded on `&System::alloc` -- against a forward declaration
// unless the plan admits the conformer complete, which fails with
// CL001E "System does not satisfy Allocator_c"; a user-defined allocator in
// the same spot always worked, because its own definition is in the TU.
import builtin::base::alloc::*

fn main() -> i32 {
    var unsafe *b = alloc_bytes<System>(8, 8)
    free_bytes<System>(b, 8, 8)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// The same with the global allocator set: Global is then a class over the
// kairo_global_* symbols, so System is reached only through the bound.
// RUN: %kairo %s -D__KAIRO_GLOBAL_ALLOCATOR_SET -o %t.set.exe --cache-dir %t.d2
// RUN: %t.set.exe
