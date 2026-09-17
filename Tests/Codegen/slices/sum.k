// RUN: { %kairo %s --type-check-only --print-cxx 2>/dev/null || true; } | %FileCheck %s --check-prefix=CXX
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
//
// A `[T;]` parameter is the Slice lang item, so codegen spells it through the
// DECL and never from a string naming a builtin type. The structural
// spellings went away with the canonical kinds.
//
// The call site is ListLiteralLowering's: `sum([1, 2, 3])` hoists the literal
// into a `[i32; 3]` temp and passes a Slice built over it, because C++ accepts
// a brace list only as a declarator's initializer -- never as an argument.
//
// Not asserted here: the emitted BODY. `--print-cxx` is the preamble only
// ("every declaration, no bodies"), and full codegen still ICEs in EmitIR, so
// there is no object to link and run yet. The lowering is pinned through the
// sema dump instead, which is where its synthesized nodes are visible.

fn sum(const xs: [i32;]) -> i32 {
    var total: i32 = 0;
    return total
}

fn call_it() -> i32 {
    return sum([1, 2, 3])
}

// DIAG-NOT: error

// The parameter's spelling comes from the Slice DECL, fully qualified through
// its module path -- no string in codegen names a builtin type. `i32` spells
// as `signed int`, and `const [T;]` binds as a const reference.
// CXX: ::builtin::containers::Slice<signed int>

// No structural container spelling survives anywhere in the output.
// CXX-NOT: VectorType
// CXX-NOT: SetType
// CXX-NOT: MapType

// The prelude dumps the builtin TUs ahead of this one: anchor on this file's
// header, or these match inside Lib/builtin instead.
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}sum.k =====
//
// ListLiteralLowering's output, both halves: the hoisted array temp, and the
// synthesized callee bound to Slice's constructor.
// SEMA:      <tu>::call_it
// SEMA-DAG:  __kairo_tmp0 {{.*}}-> var __kairo_tmp0
// SEMA-DAG:  Slice {{.*}}-> fn Slice
