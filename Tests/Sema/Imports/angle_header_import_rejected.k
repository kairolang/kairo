// A C++ header is imported with `ffi "c++" import "vector"`. The
// `import <vector>` spelling is not an import form: it is S046E at the
// import, and the later `cxx::std::vector` use does not cascade into a
// resolution error. The ffi spelling with the same body type-checks clean.

import <vector>

fn main() -> i32 {
    var v = cxx::std::vector<i32>()
    v.push_back(2)
    return v[0]
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: angle_header_import_rejected.k:6:1: error [S046E]: expected a module or symbol path after 'import'
