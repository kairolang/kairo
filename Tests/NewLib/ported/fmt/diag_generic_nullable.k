// An f-string hole with a spec on a value whose type only the instance knows is SC080E; a nullable value that is not
// proven non-null has no formatter, SC081E, with or without a spec (the same hole is fine once it is tested).
// Rules asserted (website language/generics.mdx, f-strings in a generic body: "A format spec on such a hole
// (`f"{x:>4}"`) is not supported yet"; `kairo --explain SC080E` and `--explain SC081E`: nullable values and types
// with no formatter are rejected, "test it and format the inner value").
// Not asserted because the docs do not state them: `{x:?}` on a generic value (the compiler reports SC080E for it too).
// Cases from Rust library/coretests/tests/fmt/mod.rs (generic and optional values formatted through bounds)
// Cases from the {fmt} library test/format-test.cc (formatting types with no formatter is a compile error)

fn <T> padded(x: T) -> string {
    return f"{x:>4}"
}

fn <T> centred(x: T) -> string {
    return f"{x:*^9}"
}

fn <T> plain(x: T) -> string {
    return f"{x}"
}

fn unproven(n: i32?, s: string?) -> string {
    var a = f"{n}"
    var b = f"{s}"
    var c = f"{n:>4}"
    return a
}

fn proven(n: i32?, s: string?) -> string {
    if n != null && s != null {
        return f"{n}{s}{n:>4}"
    }

    return "none"
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: { %kairo_new %s --cmax-errors=0 --type-check-only 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo_new %s --cmax-errors=0 --type-check-only 2>&1 || true; } | grep -c ' error ' | %FileCheck %s --check-prefix=COUNT
// COUNT: 5
// CHECK: :11:{{[0-9]+}}: error [SC080E]
// CHECK: :15:{{[0-9]+}}: error [SC080E]
// CHECK: :23:{{[0-9]+}}: error [SC081E]
// CHECK: :24:{{[0-9]+}}: error [SC081E]
// CHECK: :25:{{[0-9]+}}: error [SC081E]
