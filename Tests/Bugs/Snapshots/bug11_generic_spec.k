// CHARACTERIZATION SNAPSHOT -- NOT A SPECIFICATION.
//
// This file is a reproducer for a reported issue, and the checks below were
// GENERATED FROM CURRENT COMPILER OUTPUT. They record what the compiler does
// today so a change is noticed; they do NOT assert that what it does is right.
// The filename says what was reported to be wrong with it.
//
// If you are fixing that issue: expect this test to fail, and replace the
// generated block with the behaviour you intend (or XFAIL it, as
// B3-*.k and B8-*.k already are). Do not "fix" it by regenerating.
//
// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-FunctionDecl <T> sum(items: [T]) -> T
// AST-NEXT: | |-GenericParamDecl 'T'
// AST-NEXT: | `-ParamDecl items: [T]
// AST-NEXT: |-FunctionDecl  sum [spec=explicit <i32>](items: [i32]) -> i32
// AST-NEXT: | `-ParamDecl items: [i32]
// AST-NEXT: |-ClassDecl Box [spec=explicit <T>]
// AST-NEXT: | `-FieldDecl var value: T
// AST-NEXT: |-ClassDecl Box [spec=explicit <i32>]
// AST-NEXT: | `-FieldDecl var value: i32
// AST-NEXT: `-ClassDecl Box [spec=explicit <[T]>]
// AST-NEXT:   `-FieldDecl var value: [T]
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R042E]:
// AST: {{.*}}: error [R021E]:
// AST: {{.*}}: error [R021E]:
// AST: {{.*}}: error [R042E]:
// AST: {{.*}}: error [R042E]:
// AST: {{.*}}: error [R021E]:
// AST: {{.*}}: error [R021E]:
// END-GENERATED-CHECKS

fn <T> sum(items: [T]) -> T

fn <> sum<i32>(items: [i32]) -> i32

class <> Box<T> {
    var value: T
}

class <> Box<i32> {
    var value: i32
}

class <> Box<[T]> {
    var value: [T]
}
