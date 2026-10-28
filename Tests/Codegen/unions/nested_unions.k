// BEGIN-GENERATED-CHECKS(CHECK) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: |-StructDecl Packet
// CHECK-NEXT: | |-FieldDecl var opcode: u8
// CHECK-NEXT: | `-FieldDecl var payload: PacketData
// CHECK-NEXT: |-UnionDecl PacketData
// CHECK-NEXT: | |-FieldDecl var as_int: i64
// CHECK-NEXT: | |-FieldDecl var as_float: f64
// CHECK-NEXT: | `-FieldDecl var as_bytes: [u8; 8]
// CHECK-NEXT: `-FunctionDecl  main() -> i32
// CHECK-NEXT:   `-CompoundStmt (4)
// CHECK-NEXT:     |-DeclStmt
// CHECK-NEXT:     | `-VariableDecl var pkt: Packet
// CHECK-NEXT:     |-ExpressionStmt
// CHECK-NEXT:     | `-AssignOperatorExpr =
// CHECK-NEXT:     |   |-ChainExpr 'pkt.opcode'
// CHECK-NEXT:     |   | |-NamedIdentExpr pkt
// CHECK-NEXT:     |   | `-Step .opcode
// CHECK-NEXT:     |   `-IntegerLiteralExpr 1
// CHECK-NEXT:     |-ExpressionStmt
// CHECK-NEXT:     | `-AssignOperatorExpr =
// CHECK-NEXT:     |   |-ChainExpr 'pkt.payload.as_int'
// CHECK-NEXT:     |   | |-NamedIdentExpr pkt
// CHECK-NEXT:     |   | |-Step .payload
// CHECK-NEXT:     |   | `-Step .as_int
// CHECK-NEXT:     |   `-IntegerLiteralExpr 42
// CHECK-NEXT:     `-ReturnStmt
// CHECK-NEXT:       `-IntegerLiteralExpr 0
// CHECK: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS(CHECK)

struct Packet {
    var opcode: u8
    var payload: PacketData

    fn Packet(self) = default
}

union PacketData {
    var as_int: i64
    var as_float: f64
    var as_bytes: [u8; 8]
}

fn main() -> i32 {
    var pkt: Packet
    pkt.opcode = 0x01
    pkt.payload.as_int = 42
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(SEMA) mode=sema -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/nested_unions.k =====
// SEMA: -- scope symbol tables (what each scope declares) --
// SEMA-NEXT:   <tu>   [3 name(s)]
// SEMA-NEXT:     Packet      -> struct Packet @ 34:1
// SEMA-NEXT:     PacketData  -> union PacketData @ 41:1
// SEMA-NEXT:     main        -> fn main @ 47:1
// SEMA-NEXT:   <tu>::Packet   [3 name(s)]
// SEMA-NEXT:     opcode      -> field opcode @ 35:5
// SEMA-NEXT:     payload     -> field payload @ 36:5
// SEMA-NEXT:     <ctor>      -> fn Packet @ 38:5
// SEMA-NEXT:   <tu>::PacketData   [3 name(s)]
// SEMA-NEXT:     as_int      -> field as_int @ 42:5
// SEMA-NEXT:     as_float    -> field as_float @ 43:5
// SEMA-NEXT:     as_bytes    -> field as_bytes @ 44:5
// SEMA-NEXT:   lifecycle Packet: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// SEMA-NEXT: -- multi-decl names (overload sets / redecl chains) --
// SEMA: -- name bindings --
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     pkt         @ 49:5     -> var pkt @ 48:5  [local frame 0]
// SEMA-NEXT:     .opcode     @ 49:9     -> field opcode @ 35:5
// SEMA-NEXT:     pkt         @ 50:5     -> var pkt @ 48:5  [local frame 0]
// SEMA-NEXT:     .payload    @ 50:9     -> field payload @ 36:5
// SEMA-NEXT:     .as_int     @ 50:17    -> field as_int @ 42:5
// SEMA-NEXT: -- expression types --
// SEMA-NEXT:   <tu>::PacketData
// SEMA-NEXT:     IntegerLiteralExpr      @ 44:24    : <no type: callable/type/module>
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     AssignOperatorExpr      @ 49:5     : u8
// SEMA-NEXT:     ChainExpr               @ 49:5     : u8
// SEMA-NEXT:     NamedIdentExpr          @ 49:5     : Packet
// SEMA-NEXT:     IntegerLiteralExpr      @ 49:18    : u8
// SEMA-NEXT:     AssignOperatorExpr      @ 50:5     : i64
// SEMA-NEXT:     ChainExpr               @ 50:5     : i64
// SEMA-NEXT:     NamedIdentExpr          @ 50:5     : Packet
// SEMA-NEXT:     IntegerLiteralExpr      @ 50:26    : i64
// SEMA-NEXT:     IntegerLiteralExpr      @ 51:12    : i32
// SEMA-NEXT:   9 typed, 0 unknown, 0 errored
// SEMA-NEXT: -- inferred decls --
// SEMA-NEXT:   (none: every declaration wrote its own type)
// SEMA-NEXT: -- interface composition --
// SEMA-NEXT: -- types --
// END-GENERATED-CHECKS(SEMA)

// BEGIN-GENERATED-CHECKS(LOWERED) mode=lowered -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-lowered 2>/dev/null || true; } | %FileCheck %s --check-prefix=LOWERED
// LOWERED: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/nested_unions.k =====
// LOWERED: -- scope symbol tables (what each scope declares) --
// LOWERED-NEXT:   <tu>   [3 name(s)]
// LOWERED-NEXT:     Packet      -> struct Packet @ 34:1
// LOWERED-NEXT:     PacketData  -> union PacketData @ 41:1
// LOWERED-NEXT:     main        -> fn main @ 47:1
// LOWERED-NEXT:   <tu>::Packet   [3 name(s)]
// LOWERED-NEXT:     opcode      -> field opcode @ 35:5
// LOWERED-NEXT:     payload     -> field payload @ 36:5
// LOWERED-NEXT:     <ctor>      -> fn Packet @ 38:5
// LOWERED-NEXT:   <tu>::PacketData   [3 name(s)]
// LOWERED-NEXT:     as_int      -> field as_int @ 42:5
// LOWERED-NEXT:     as_float    -> field as_float @ 43:5
// LOWERED-NEXT:     as_bytes    -> field as_bytes @ 44:5
// LOWERED-NEXT:   lifecycle Packet: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// LOWERED-NEXT: -- multi-decl names (overload sets / redecl chains) --
// LOWERED: -- name bindings --
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     pkt         @ 49:5     -> var pkt @ 48:5  [local frame 0]
// LOWERED-NEXT:     .opcode     @ 49:9     -> field opcode @ 35:5
// LOWERED-NEXT:     pkt         @ 50:5     -> var pkt @ 48:5  [local frame 0]
// LOWERED-NEXT:     .payload    @ 50:9     -> field payload @ 36:5
// LOWERED-NEXT:     .as_int     @ 50:17    -> field as_int @ 42:5
// LOWERED-NEXT: -- expression types --
// LOWERED-NEXT:   <tu>::PacketData
// LOWERED-NEXT:     IntegerLiteralExpr      @ 44:24    : <no type: callable/type/module>
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     AssignOperatorExpr      @ 49:5     : u8
// LOWERED-NEXT:     ChainExpr               @ 49:5     : u8
// LOWERED-NEXT:     NamedIdentExpr          @ 49:5     : Packet
// LOWERED-NEXT:     IntegerLiteralExpr      @ 49:18    : u8
// LOWERED-NEXT:     AssignOperatorExpr      @ 50:5     : i64
// LOWERED-NEXT:     ChainExpr               @ 50:5     : i64
// LOWERED-NEXT:     NamedIdentExpr          @ 50:5     : Packet
// LOWERED-NEXT:     IntegerLiteralExpr      @ 50:26    : i64
// LOWERED-NEXT:     IntegerLiteralExpr      @ 51:12    : i32
// LOWERED-NEXT:   9 typed, 0 unknown, 0 errored
// LOWERED-NEXT: -- inferred decls --
// LOWERED-NEXT:   (none: every declaration wrote its own type)
// LOWERED-NEXT: -- interface composition --
// LOWERED-NEXT: -- types --
// END-GENERATED-CHECKS(LOWERED)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 0
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
