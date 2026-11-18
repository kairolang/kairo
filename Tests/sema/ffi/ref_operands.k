// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Operands of C++ REFERENCE type. `vector<i32>::at` returns `i32&`, and an
// expression of reference type is the referent ([expr.type]/1), so every
// operator classifies the referee: `+` is integer arithmetic, `+=` and `=`
// assign the object the reference names, and `-` negates an `i32`. Before
// TypeUtil::as_value the operand stayed an `i32&`, whose kind_of is COUNT --
// each of these looked like a record with no `op` member and was rejected.

ffi "c++" import "vector"

fn ref_operands() -> i32 {
    var v: cxx::std::vector<i32>
    v.push_back(1)

    var a = v.at(0) + 1
    v.at(0) += 2
    v.at(0) = 3
    var n = -v.at(0)

    return a + n
}

// DIAG-NOT: error

// SEMA-DAG: a : i32
// SEMA-DAG: n : i32
