// A match over an ADT switches on the tag and reads each binder out of the
// live variant's payload. Binders bind by field name, any subset of the
// payload's fields; a `var` binder is the arm's own copy, a `const` one a
// read-only view. Value form and statement form, a guard that falls through
// to a later arm of the same variant, a payload-less variant, and default
// for the variant no arm names.

enum <K, V> LookupResult { Found { key: K, value: V }, NotFound { key: K }, Error { message: string }, Empty }

// An arm whose whole value is a `var` binder hands the binder over: it is
// the arm's own copy, and nothing reads it after the arm.
fn value_of(r: LookupResult<i32, string>) -> string = match r {
    case .Found(var value)   => value
    case .Error(var message) => message
    default                  => "none"
}

fn score(const r: LookupResult<i32, string>) -> i32 = match r {
    case .Found(const key, const value) where key > 10 => key + (value.len as i32)
    case .Found(var key)    => key
    case .NotFound(var key) => -key
    case .Empty             => 100
    default                 => 0
}

fn tally(r: LookupResult<i32, string>) -> i32 {
    var acc: i32 = 0
    match r {
        case .Found(const value) where value.len == 0 { acc = 1; }
        case .Found(var key)                          { key += 1; acc = key; }
        case .Empty                                   { acc = 7; }
        default                                       { acc = 9; }
    }
    return acc
}

// Writing a `var` binder leaves the scrutinee alone.
fn rebind() -> bool {
    var r = LookupResult<i32, string>::Found { key: 1, value: "a" }
    match r {
        case .Found(var key) { key = 50; }
        default              { }
    }
    return score(r) == 1
}

fn main() -> i32 {
    var f = LookupResult<i32, string>::Found { key: 20, value: "abc" }
    var g = LookupResult<i32, string>::Found { key: 3, value: "xy" }
    var n = LookupResult<i32, string>::NotFound { key: 4 }
    var e = LookupResult<i32, string>::Error { message: "bad!" }
    var z: LookupResult<i32, string> = .Empty
    var r = 0
    if (score(f) == 23) && (score(g) == 3) && (score(n) == -4) && (score(z) == 100) && (score(e) == 0) { r += 1 }
    if (value_of(f).len == 3) && (value_of(e).len == 4) && (value_of(z).len == 4) { r += 2 }
    if (tally(LookupResult<i32, string>::Found { key: 5, value: "" }) == 1) && (tally(f) == 21) { r += 4 }
    if (tally(z) == 7) && (tally(n) == 9) && (tally(e) == 9) { r += 8 }
    if rebind() { r += 16 }
    return r                                    // 31
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The decision trees: a switch on the tag, each binder a path into the
// live payload, the guarded arm falling back to the unguarded one.
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA-LABEL: SEMA fid {{[0-9]+}}: {{.*}}match.k
// SEMA:      -- expression types --
// SEMA:      <tu>::value_of
// SEMA-NEXT:   MatchExpr {{.*}}: string  [exhaustive=1
// SEMA:        {{n[0-9]+}}: switch $ { .Found => {{n[0-9]+}}, .Error => {{n[0-9]+}}, _ => {{n[0-9]+}} }
// SEMA:        {{n[0-9]+}}: leaf arm 0 [value=$.Found.value]
// SEMA:        {{n[0-9]+}}: leaf arm 1 [message=$.Error.message]
// SEMA:      <tu>::score
// SEMA-NEXT:   MatchExpr {{.*}}: i32  [exhaustive=1
// SEMA:        {{n[0-9]+}}: switch $ { .Found => {{n[0-9]+}}, .NotFound => {{n[0-9]+}}, .Empty => {{n[0-9]+}}, _ => {{n[0-9]+}} }
// SEMA-DAG:    {{n[0-9]+}}: leaf arm 1 [key=$.Found.key]
// SEMA-DAG:    {{n[0-9]+}}: guard arm 0 else {{n[0-9]+}} [key=$.Found.key value=$.Found.value]
// SEMA-DAG:    {{n[0-9]+}}: leaf arm 2 [key=$.NotFound.key]
// SEMA:      <tu>::tally

// The binder is read out of the payload through the union member, and the
// arm's value moves out of it.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}match.k
// IR:       switch(static_cast<unsigned int>(__kairo_m{{[0-9]+}}_s.__kairo_tag)) {
// IR:       ::builtin::string::string value = __kairo_m{{[0-9]+}}_s.__kairo_Found.value;
// IR-NEXT:  (static_cast<{{ ?}}::builtin::string::string{{ ?}}&&>(value));

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 31
