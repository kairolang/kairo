// --cmax-scope-depth limits the user's code only. At a cap of 4 the builtin
// and std sources (which nest deeper) still parse and check, so the one
// nesting error is the one in this file, at the `if` that crosses the cap.
// A generous cap leaves the same program clean.

fn main() -> i32 {
    if true {
        if true {
            if true {
                if true {
                    return 1
                }
            }
        }
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --type-check-only --cmax-scope-depth=4 %s 2>&1 || true; } | %FileCheck %s --check-prefix=LOW --implicit-check-not=error
// RUN: %kairo --type-check-only --cmax-scope-depth=256 %s
// LOW: cmax_scope_depth_user_code.k:8:9: error [S063E]: exceeded maximum nesting depth
