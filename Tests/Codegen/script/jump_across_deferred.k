// A `jump!` at the top level of a script that crosses the line of a
// deferred script variable is an error, in either direction (SCRIPT.md
// 2.7, decided). Forward, it would skip the initializer while every read
// after the label is compiled unchecked, as proven by main's order; back,
// it would run statements again around a line the order says ran once.
// JumpLabelCheck reports it, on the same "constant initializer" rule
// ScriptLowering defers by, so a jump past a constant binding (`K`) or one
// that crosses no line at all is not this error.
//
// Every user `label!` / `jump!` is still SC116E ("not yet supported"):
// that gate stays until a jump inside a function body is proven to cross
// no local initialization either. Both errors are reported.

import std::io::println

fn load() -> i32 { return 1 }

jump!(over)
var g = load()
label!(over)
println(f"{g}")

jump!(past_k)
var K: i32 = -1
label!(past_k)

label!(back)
var h = load()
println(f"{h}")
if h == 0 { jump!(back) }

label!(here)
jump!(here)

// A function body is its own frame: its jumps are not main's, and no
// script line is between them.
fn inner() {
    jump!(done)
    label!(done)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-DAG: jump_across_deferred.k:18:1: error [SC001E]: this 'jump!' crosses the line that gives script variable 'g' its value
// DIAG-DAG: jump_across_deferred.k:19:1: note [SC001N]: 'g' is given its value here; a jump past it would skip it, and reads after the label are not checked
// DIAG-DAG: jump_across_deferred.k:20:1: note [SC001N]: the jump lands here
// DIAG-DAG: jump_across_deferred.k:30:13: error [SC001E]: this 'jump!' crosses the line that gives script variable 'h' its value
// DIAG-DAG: jump_across_deferred.k:28:1: note [SC001N]: 'h' is given its value here; a jump back over it would run it again
// DIAG-DAG: jump_across_deferred.k:27:1: note [SC001N]: the jump lands here
// DIAG-DAG: jump_across_deferred.k:18:1: error [SC116E]: 'jump!' is not yet supported
// DIAG-DAG: jump_across_deferred.k:23:1: error [SC116E]: 'jump!' is not yet supported
// DIAG-DAG: jump_across_deferred.k:30:13: error [SC116E]: 'jump!' is not yet supported
// DIAG-DAG: jump_across_deferred.k:33:1: error [SC116E]: 'jump!' is not yet supported
//
// Exactly two crossings: not the jump past K (constant), not the one to
// `here` (no line between), not the one in `inner`.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | grep -c "crosses the line" | %FileCheck %s --check-prefix=COUNT
// COUNT: 2
