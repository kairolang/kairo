// Tests/Codegen/unions/union_hold_struct.k
// build: kairo union_holds_struct.k   (expect exit 0)
// The reverse edge: the union holds a struct declared after it by value, and
// a struct holds that union by value. Little-endian layout assumed.
struct HardwareRegister {
    var address: usize
    var value: RegValue
}

union RegValue {
    var raw: u32
    var fields: RegFields
}

struct RegFields {
    var low: u16
    var high: u16
}

fn main() -> i32 {
    var reg = HardwareRegister { address: 0, value: RegValue{ raw: 0 } }
    if (reg.value.fields.low == 0) && (reg.value.fields.high == 0) { return 0 }
    return 1
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(SEMA) mode=sema -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/union_hold_struct.k =====
// SEMA: -- scope symbol tables (what each scope declares) --
// SEMA-NEXT:   <tu>   [4 name(s)]
// SEMA-NEXT:     HardwareRegister -> struct HardwareRegister @ 5:1
// SEMA-NEXT:     RegValue    -> union RegValue @ 10:1
// SEMA-NEXT:     RegFields   -> struct RegFields @ 15:1
// SEMA-NEXT:     main        -> fn main @ 20:1
// SEMA-NEXT:   <tu>::HardwareRegister   [2 name(s)]
// SEMA-NEXT:     address     -> field address @ 6:5
// SEMA-NEXT:     value       -> field value @ 7:5
// SEMA-NEXT:   <tu>::RegValue   [2 name(s)]
// SEMA-NEXT:     raw         -> field raw @ 11:5
// SEMA-NEXT:     fields      -> field fields @ 12:5
// SEMA-NEXT:   <tu>::RegFields   [2 name(s)]
// SEMA-NEXT:     low         -> field low @ 16:5
// SEMA-NEXT:     high        -> field high @ 17:5
// SEMA-NEXT:   lifecycle HardwareRegister: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// SEMA-NEXT:   lifecycle RegFields: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// SEMA-NEXT: -- multi-decl names (overload sets / redecl chains) --
// SEMA: -- name bindings --
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     HardwareRegister @ 21:15    -> struct HardwareRegister @ 5:1  [scope <tu>]
// SEMA-NEXT:     RegValue    @ 21:53    -> union RegValue @ 10:1  [scope <tu>]
// SEMA-NEXT:     reg         @ 22:9     -> var reg @ 21:5  [local frame 0]
// SEMA-NEXT:     .value      @ 22:13    -> field value @ 7:5
// SEMA-NEXT:     .fields     @ 22:19    -> field fields @ 12:5
// SEMA-NEXT:     .low        @ 22:26    -> field low @ 16:5
// SEMA-NEXT:     reg         @ 22:40    -> var reg @ 21:5  [local frame 0]
// SEMA-NEXT:     .value      @ 22:44    -> field value @ 7:5
// SEMA-NEXT:     .fields     @ 22:50    -> field fields @ 12:5
// SEMA-NEXT:     .high       @ 22:57    -> field high @ 17:5
// SEMA-NEXT: -- expression types --
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     NamedInitializerExpr    @ 21:15    : HardwareRegister
// SEMA-NEXT:     NamedIdentExpr          @ 21:15    : <no type: callable/type/module>
// SEMA-NEXT:     IntegerLiteralExpr      @ 21:43    : usize
// SEMA-NEXT:     NamedInitializerExpr    @ 21:53    : RegValue
// SEMA-NEXT:     NamedIdentExpr          @ 21:53    : <no type: callable/type/module>
// SEMA-NEXT:     IntegerLiteralExpr      @ 21:68    : u32
// SEMA-NEXT:     BinaryOperatorExpr      @ 22:9     : bool
// SEMA-NEXT:     BinaryOperatorExpr      @ 22:9     : bool
// SEMA-NEXT:     ChainExpr               @ 22:9     : u16
// SEMA-NEXT:     NamedIdentExpr          @ 22:9     : HardwareRegister
// SEMA-NEXT:     IntegerLiteralExpr      @ 22:33    : u16
// SEMA-NEXT:     BinaryOperatorExpr      @ 22:40    : bool
// SEMA-NEXT:     ChainExpr               @ 22:40    : u16
// SEMA-NEXT:     NamedIdentExpr          @ 22:40    : HardwareRegister
// SEMA-NEXT:     IntegerLiteralExpr      @ 22:65    : u16
// SEMA-NEXT:     IntegerLiteralExpr      @ 22:77    : i32
// SEMA-NEXT:     IntegerLiteralExpr      @ 23:12    : i32
// SEMA-NEXT:   15 typed, 0 unknown, 0 errored
// SEMA-NEXT: -- inferred decls --
// SEMA-NEXT:   reg : HardwareRegister
// SEMA-NEXT: -- types --
// END-GENERATED-CHECKS(SEMA)

// BEGIN-GENERATED-CHECKS(LOWERED) mode=lowered -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-lowered 2>/dev/null || true; } | %FileCheck %s --check-prefix=LOWERED
// LOWERED: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/union_hold_struct.k =====
// LOWERED: -- scope symbol tables (what each scope declares) --
// LOWERED-NEXT:   <tu>   [4 name(s)]
// LOWERED-NEXT:     HardwareRegister -> struct HardwareRegister @ 5:1
// LOWERED-NEXT:     RegValue    -> union RegValue @ 10:1
// LOWERED-NEXT:     RegFields   -> struct RegFields @ 15:1
// LOWERED-NEXT:     main        -> fn main @ 20:1
// LOWERED-NEXT:   <tu>::HardwareRegister   [2 name(s)]
// LOWERED-NEXT:     address     -> field address @ 6:5
// LOWERED-NEXT:     value       -> field value @ 7:5
// LOWERED-NEXT:   <tu>::RegValue   [2 name(s)]
// LOWERED-NEXT:     raw         -> field raw @ 11:5
// LOWERED-NEXT:     fields      -> field fields @ 12:5
// LOWERED-NEXT:   <tu>::RegFields   [2 name(s)]
// LOWERED-NEXT:     low         -> field low @ 16:5
// LOWERED-NEXT:     high        -> field high @ 17:5
// LOWERED-NEXT:   lifecycle HardwareRegister: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// LOWERED-NEXT:   lifecycle RegFields: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// LOWERED-NEXT: -- multi-decl names (overload sets / redecl chains) --
// LOWERED: -- name bindings --
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     HardwareRegister @ 21:15    -> struct HardwareRegister @ 5:1  [scope <tu>]
// LOWERED-NEXT:     RegValue    @ 21:53    -> union RegValue @ 10:1  [scope <tu>]
// LOWERED-NEXT:     reg         @ 22:9     -> var reg @ 21:5  [local frame 0]
// LOWERED-NEXT:     .value      @ 22:13    -> field value @ 7:5
// LOWERED-NEXT:     .fields     @ 22:19    -> field fields @ 12:5
// LOWERED-NEXT:     .low        @ 22:26    -> field low @ 16:5
// LOWERED-NEXT:     reg         @ 22:40    -> var reg @ 21:5  [local frame 0]
// LOWERED-NEXT:     .value      @ 22:44    -> field value @ 7:5
// LOWERED-NEXT:     .fields     @ 22:50    -> field fields @ 12:5
// LOWERED-NEXT:     .high       @ 22:57    -> field high @ 17:5
// LOWERED-NEXT: -- expression types --
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     NamedInitializerExpr    @ 21:15    : HardwareRegister
// LOWERED-NEXT:     NamedIdentExpr          @ 21:15    : <no type: callable/type/module>
// LOWERED-NEXT:     IntegerLiteralExpr      @ 21:43    : usize
// LOWERED-NEXT:     NamedInitializerExpr    @ 21:53    : RegValue
// LOWERED-NEXT:     NamedIdentExpr          @ 21:53    : <no type: callable/type/module>
// LOWERED-NEXT:     IntegerLiteralExpr      @ 21:68    : u32
// LOWERED-NEXT:     BinaryOperatorExpr      @ 22:9     : bool
// LOWERED-NEXT:     BinaryOperatorExpr      @ 22:9     : bool
// LOWERED-NEXT:     ChainExpr               @ 22:9     : u16
// LOWERED-NEXT:     NamedIdentExpr          @ 22:9     : HardwareRegister
// LOWERED-NEXT:     IntegerLiteralExpr      @ 22:33    : u16
// LOWERED-NEXT:     BinaryOperatorExpr      @ 22:40    : bool
// LOWERED-NEXT:     ChainExpr               @ 22:40    : u16
// LOWERED-NEXT:     NamedIdentExpr          @ 22:40    : HardwareRegister
// LOWERED-NEXT:     IntegerLiteralExpr      @ 22:65    : u16
// LOWERED-NEXT:     IntegerLiteralExpr      @ 22:77    : i32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 23:12    : i32
// LOWERED-NEXT:   15 typed, 0 unknown, 0 errored
// LOWERED-NEXT: -- inferred decls --
// LOWERED-NEXT:   reg : HardwareRegister
// LOWERED-NEXT: -- types --
// END-GENERATED-CHECKS(LOWERED)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 0
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
