ffi "c++" import "ffi_ref_return.h"
ffi "c++" import "ffi_ref_return_string.h"

class N derives Named {
    pub var s: cxx::std::string
    override fn name(const self) -> ffi::ref<cxx::std::string> { return self.s }
}

class D derives Base {
    pub var mine: i32 = 1
    override fn pick(self) -> i32 { return self.mine }
    override fn peek(const self) -> ffi::ref<i32> { return self.mine }
    override fn take(self) -> ffi::ref<i32> { return self.mine }
    override fn val(self) -> ffi::ref<i32> { return self.mine }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// An override of a C++ virtual returns exactly what the virtual returns
// when either side is a reference; each mismatch is one SC294E with the
// right spelling as its fix-it, which keeps the user's spelling of a class
// referee (clang would reject the pair later, naming C++ types and offering
// nothing). Red on a compiler without `ffi::ref`.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: ffi_ref_return_override_mismatch.k:6:37: error [SC294E]: 'name' returns 'ffi::ref<cxx::std::string>', but the C++ virtual it overrides returns 'ffi::ref<const cxx::std::string>'
// DIAG-NEXT: fix-it:{{.*}}:{6:37-6:63}:"ffi::ref<const cxx::std::string>"
// DIAG: ffi_ref_return_override_mismatch.k:11:31: error [SC294E]: 'pick' returns 'i32', but the C++ virtual it overrides returns 'ffi::ref<i32>'
// DIAG-NEXT: fix-it:{{.*}}:{11:31-11:34}:"ffi::ref<i32>"
// DIAG-NEXT: ffi_ref_return.h:{{[0-9]+}}:{{[0-9]+}}: note [SC294N]: the C++ virtual it overrides, whose return it must match
// DIAG: ffi_ref_return_override_mismatch.k:12:37: error [SC294E]: 'peek' returns 'ffi::ref<i32>', but the C++ virtual it overrides returns 'ffi::ref<const i32>'
// DIAG-NEXT: fix-it:{{.*}}:{12:37-12:50}:"ffi::ref<const i32>"
// DIAG: ffi_ref_return_override_mismatch.k:13:31: error [SC294E]: 'take' returns 'ffi::ref<i32>', but the C++ virtual it overrides returns 'ffi::mref<i32>'
// DIAG-NEXT: fix-it:{{.*}}:{13:31-13:44}:"ffi::mref<i32>"
// DIAG: ffi_ref_return_override_mismatch.k:14:30: error [SC294E]: 'val' returns 'ffi::ref<i32>', but the C++ virtual it overrides returns 'i32'
// DIAG-NEXT: fix-it:{{.*}}:{14:30-14:43}:"i32"
