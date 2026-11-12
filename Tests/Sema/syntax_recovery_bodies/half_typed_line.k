// `var x = v +` with the body's `}` on the next line, the most common
// half-typed line in an editor. The failed operand leaves the `}` for the
// body, so the body closes on its own brace and keeps its one error: with
// --check-past-syntax-errors the file is checked without that body (partial,
// not unchecked), so the healthy function below it is checked (its type
// error is reported) and the call into the broken one says nothing.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=OFF --implicit-check-not=error
// RUN: { %kairo %s --type-check-only --check-past-syntax-errors 2>&1 || true; } | %FileCheck %s --check-prefix=ON --implicit-check-not=error
// RUN: { env KAIRO_DEBUG_SYNTAX_RECOVERY=1 %kairo %s --type-check-only --check-past-syntax-errors 2>&1 || true; } | %FileCheck %s --check-prefix=DBG
//
// OFF: half_typed_line.k:20:1: error [S052E]: expected expression, found '}'
// ON-DAG: half_typed_line.k:20:1: error [S052E]: expected expression, found '}'
// ON-DAG: half_typed_line.k:23:18: error [SC028E]: cannot convert 'string' to 'i32'
// DBG-DAG: syntax-recovery: dropped body {{.*}}half_typed_line.k:18-20
// DBG-DAG: syntax-recovery: entry checked, 0 of {{[0-9]+}} files skipped, 1 checked without their broken bodies

fn broken(v: i32) -> i32 {
    var x = v +
}

fn below(v: i32) -> i32 {
    var z: i32 = "checked"
    return v + broken(v)
}

fn main() -> i32 {
    return below(1)
}
