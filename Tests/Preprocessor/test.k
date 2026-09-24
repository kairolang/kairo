// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-ModuleDecl std
// AST-NEXT: |-ModuleDecl foo
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-RecoveryExpr trying: ChainExpr
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-ListLiteralExpr (8)
// AST-NEXT: |   |-CallExpr (0 args)
// AST-NEXT: |   | `-ClosureExpr
// AST-NEXT: |   |   `-CaptureList (explicit no capture)
// AST-NEXT: |   |   `-CompoundStmt (2)
// AST-NEXT: |   |     |-DeclStmt
// AST-NEXT: |   |     | `-VariableDecl var str
// AST-NEXT: |   |     |   `-CallExpr (1 args)
// AST-NEXT: |   |     |     |-ChainExpr 'std::to_string'
// AST-NEXT: |   |     |     | |-NamedIdentExpr std
// AST-NEXT: |   |     |     | `-Step ::to_string
// AST-NEXT: |   |     |     `-StringLiteralExpr "hello"
// AST-NEXT: |   |     `-ExpressionStmt
// AST-NEXT: |   |       `-CallExpr (3 args)
// AST-NEXT: |   |         |-NamedIdentExpr fprintf
// AST-NEXT: |   |         |-NamedIdentExpr stderr
// AST-NEXT: |   |         |-StringLiteralExpr "%s"
// AST-NEXT: |   |         `-CallExpr (0 args)
// AST-NEXT: |   |           `-ChainExpr 'str.raw'
// AST-NEXT: |   |             |-NamedIdentExpr str
// AST-NEXT: |   |             `-Step .raw
// AST-NEXT: |   |-CallExpr (0 args)
// AST-NEXT: |   | `-ClosureExpr
// AST-NEXT: |   |   `-CaptureList (explicit no capture)
// AST-NEXT: |   |   `-CompoundStmt (2)
// AST-NEXT: |   |     |-DeclStmt
// AST-NEXT: |   |     | `-VariableDecl var str
// AST-NEXT: |   |     |   `-CallExpr (1 args)
// AST-NEXT: |   |     |     |-ChainExpr 'std::to_string'
// AST-NEXT: |   |     |     | |-NamedIdentExpr std
// AST-NEXT: |   |     |     | `-Step ::to_string
// AST-NEXT: |   |     |     `-IntegerLiteralExpr 1
// AST-NEXT: |   |     `-ExpressionStmt
// AST-NEXT: |   |       `-CallExpr (3 args)
// AST-NEXT: |   |         |-NamedIdentExpr fprintf
// AST-NEXT: |   |         |-NamedIdentExpr stderr
// AST-NEXT: |   |         |-StringLiteralExpr "%s"
// AST-NEXT: |   |         `-CallExpr (0 args)
// AST-NEXT: |   |           `-ChainExpr 'str.raw'
// AST-NEXT: |   |             |-NamedIdentExpr str
// AST-NEXT: |   |             `-Step .raw
// AST-NEXT: |   |-CallExpr (0 args)
// AST-NEXT: |   | `-ClosureExpr
// AST-NEXT: |   |   `-CaptureList (explicit no capture)
// AST-NEXT: |   |   `-CompoundStmt (2)
// AST-NEXT: |   |     |-DeclStmt
// AST-NEXT: |   |     | `-VariableDecl var str
// AST-NEXT: |   |     |   `-CallExpr (1 args)
// AST-NEXT: |   |     |     |-ChainExpr 'std::to_string'
// AST-NEXT: |   |     |     | |-NamedIdentExpr std
// AST-NEXT: |   |     |     | `-Step ::to_string
// AST-NEXT: |   |     |     `-IntegerLiteralExpr 2
// AST-NEXT: |   |     `-ExpressionStmt
// AST-NEXT: |   |       `-CallExpr (3 args)
// AST-NEXT: |   |         |-NamedIdentExpr fprintf
// AST-NEXT: |   |         |-NamedIdentExpr stderr
// AST-NEXT: |   |         |-StringLiteralExpr "%s"
// AST-NEXT: |   |         `-CallExpr (0 args)
// AST-NEXT: |   |           `-ChainExpr 'str.raw'
// AST-NEXT: |   |             |-NamedIdentExpr str
// AST-NEXT: |   |             `-Step .raw
// AST-NEXT: |   |-CallExpr (0 args)
// AST-NEXT: |   | `-ClosureExpr
// AST-NEXT: |   |   `-CaptureList (explicit no capture)
// AST-NEXT: |   |   `-CompoundStmt (2)
// AST-NEXT: |   |     |-DeclStmt
// AST-NEXT: |   |     | `-VariableDecl var str
// AST-NEXT: |   |     |   `-CallExpr (1 args)
// AST-NEXT: |   |     |     |-ChainExpr 'std::to_string'
// AST-NEXT: |   |     |     | |-NamedIdentExpr std
// AST-NEXT: |   |     |     | `-Step ::to_string
// AST-NEXT: |   |     |     `-IntegerLiteralExpr 3
// AST-NEXT: |   |     `-ExpressionStmt
// AST-NEXT: |   |       `-CallExpr (3 args)
// AST-NEXT: |   |         |-NamedIdentExpr fprintf
// AST-NEXT: |   |         |-NamedIdentExpr stderr
// AST-NEXT: |   |         |-StringLiteralExpr "%s"
// AST-NEXT: |   |         `-CallExpr (0 args)
// AST-NEXT: |   |           `-ChainExpr 'str.raw'
// AST-NEXT: |   |             |-NamedIdentExpr str
// AST-NEXT: |   |             `-Step .raw
// AST-NEXT: |   |-CallExpr (0 args)
// AST-NEXT: |   | `-ClosureExpr
// AST-NEXT: |   |   `-CaptureList (explicit no capture)
// AST-NEXT: |   |   `-CompoundStmt (2)
// AST-NEXT: |   |     |-DeclStmt
// AST-NEXT: |   |     | `-VariableDecl var str
// AST-NEXT: |   |     |   `-CallExpr (1 args)
// AST-NEXT: |   |     |     |-ChainExpr 'std::to_string'
// AST-NEXT: |   |     |     | |-NamedIdentExpr std
// AST-NEXT: |   |     |     | `-Step ::to_string
// AST-NEXT: |   |     |     `-StringLiteralExpr "world"
// AST-NEXT: |   |     `-ExpressionStmt
// AST-NEXT: |   |       `-CallExpr (3 args)
// AST-NEXT: |   |         |-NamedIdentExpr fprintf
// AST-NEXT: |   |         |-NamedIdentExpr stderr
// AST-NEXT: |   |         |-StringLiteralExpr "%s"
// AST-NEXT: |   |         `-CallExpr (0 args)
// AST-NEXT: |   |           `-ChainExpr 'str.raw'
// AST-NEXT: |   |             |-NamedIdentExpr str
// AST-NEXT: |   |             `-Step .raw
// AST-NEXT: |   |-CallExpr (0 args)
// AST-NEXT: |   | `-ClosureExpr
// AST-NEXT: |   |   `-CaptureList (explicit no capture)
// AST-NEXT: |   |   `-CompoundStmt (2)
// AST-NEXT: |   |     |-DeclStmt
// AST-NEXT: |   |     | `-VariableDecl var str
// AST-NEXT: |   |     |   `-CallExpr (1 args)
// AST-NEXT: |   |     |     |-ChainExpr 'std::to_string'
// AST-NEXT: |   |     |     | |-NamedIdentExpr std
// AST-NEXT: |   |     |     | `-Step ::to_string
// AST-NEXT: |   |     |     `-IntegerLiteralExpr 4
// AST-NEXT: |   |     `-ExpressionStmt
// AST-NEXT: |   |       `-CallExpr (3 args)
// AST-NEXT: |   |         |-NamedIdentExpr fprintf
// AST-NEXT: |   |         |-NamedIdentExpr stderr
// AST-NEXT: |   |         |-StringLiteralExpr "%s"
// AST-NEXT: |   |         `-CallExpr (0 args)
// AST-NEXT: |   |           `-ChainExpr 'str.raw'
// AST-NEXT: |   |             |-NamedIdentExpr str
// AST-NEXT: |   |             `-Step .raw
// AST-NEXT: |   |-CallExpr (0 args)
// AST-NEXT: |   | `-ClosureExpr
// AST-NEXT: |   |   `-CaptureList (explicit no capture)
// AST-NEXT: |   |   `-CompoundStmt (2)
// AST-NEXT: |   |     |-DeclStmt
// AST-NEXT: |   |     | `-VariableDecl var str
// AST-NEXT: |   |     |   `-CallExpr (1 args)
// AST-NEXT: |   |     |     |-ChainExpr 'std::to_string'
// AST-NEXT: |   |     |     | |-NamedIdentExpr std
// AST-NEXT: |   |     |     | `-Step ::to_string
// AST-NEXT: |   |     |     `-IntegerLiteralExpr 5
// AST-NEXT: |   |     `-ExpressionStmt
// AST-NEXT: |   |       `-CallExpr (3 args)
// AST-NEXT: |   |         |-NamedIdentExpr fprintf
// AST-NEXT: |   |         |-NamedIdentExpr stderr
// AST-NEXT: |   |         |-StringLiteralExpr "%s"
// AST-NEXT: |   |         `-CallExpr (0 args)
// AST-NEXT: |   |           `-ChainExpr 'str.raw'
// AST-NEXT: |   |             |-NamedIdentExpr str
// AST-NEXT: |   |             `-Step .raw
// AST-NEXT: |   `-CallExpr (0 args)
// AST-NEXT: |     `-ClosureExpr
// AST-NEXT: |       `-CaptureList (explicit no capture)
// AST-NEXT: |       `-CompoundStmt (2)
// AST-NEXT: |         |-DeclStmt
// AST-NEXT: |         | `-VariableDecl var str
// AST-NEXT: |         |   `-CallExpr (1 args)
// AST-NEXT: |         |     |-ChainExpr 'std::to_string'
// AST-NEXT: |         |     | |-NamedIdentExpr std
// AST-NEXT: |         |     | `-Step ::to_string
// AST-NEXT: |         |     `-IntegerLiteralExpr 6
// AST-NEXT: |         `-ExpressionStmt
// AST-NEXT: |           `-CallExpr (3 args)
// AST-NEXT: |             |-NamedIdentExpr fprintf
// AST-NEXT: |             |-NamedIdentExpr stderr
// AST-NEXT: |             |-StringLiteralExpr "%s"
// AST-NEXT: |             `-CallExpr (0 args)
// AST-NEXT: |               `-ChainExpr 'str.raw'
// AST-NEXT: |                 |-NamedIdentExpr str
// AST-NEXT: |                 `-Step .raw
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var __synth_str_0_1
// AST-NEXT: |   `-CallExpr (1 args)
// AST-NEXT: |     |-ChainExpr 'std::to_string'
// AST-NEXT: |     | |-NamedIdentExpr std
// AST-NEXT: |     | `-Step ::to_string
// AST-NEXT: |     `-NamedIdentExpr t
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-CallExpr (3 args)
// AST-NEXT:     |-NamedIdentExpr fprintf
// AST-NEXT:     |-NamedIdentExpr stderr
// AST-NEXT:     |-StringLiteralExpr "%s"
// AST-NEXT:     `-CallExpr (0 args)
// AST-NEXT:       `-ChainExpr '__synth_str_0_1.raw'
// AST-NEXT:         |-NamedIdentExpr __synth_str_0_1
// AST-NEXT:         `-Step .raw
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R013E]:
// END-GENERATED-CHECKS

module std {
    macro eprint!(...t) {
        [(fn ()||  {
            var str = std::to_string(t);
            fprintf(stderr, "%s", str.raw());
        }())...]
    }
}

module foo {
    macro eprint!(...t) {
        var unique_id!(str) = std::to_string(t);
        fprintf(stderr, "%s", unique_id!(str).raw());
    }
}


eprint!("hello", 1, 2, 3, "world", 4, 5, 6)
std::eprint!("hello", 1, 2, 3, "world", 4, 5, 6)
foo::eprint!("hello", 1, 2, 3, "world", 4, 5, 6)
