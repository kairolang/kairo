// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-ClassDecl Stack
// AST-NEXT: | |-FieldDecl var items: [T]
// AST-NEXT: | |-FunctionDecl  Stack(self)
// AST-NEXT: | | |-ParamDecl self
// AST-NEXT: | | `-CompoundStmt (0)
// AST-NEXT: | |-FunctionDecl  push(self, v: T)
// AST-NEXT: | | |-ParamDecl self
// AST-NEXT: | | |-ParamDecl v: T
// AST-NEXT: | | `-CompoundStmt (1)
// AST-NEXT: | |   `-ExpressionStmt
// AST-NEXT: | |     `-CallExpr (1 args)
// AST-NEXT: | |       |-ChainExpr 'self.items.push'
// AST-NEXT: | |       | |-NamedIdentExpr self
// AST-NEXT: | |       | |-Step .items
// AST-NEXT: | |       | `-Step .push
// AST-NEXT: | |       `-NamedIdentExpr v
// AST-NEXT: | |-FunctionDecl  twin(self) -> Self
// AST-NEXT: | | |-ParamDecl self
// AST-NEXT: | | `-CompoundStmt (1)
// AST-NEXT: | |   `-ReturnStmt
// AST-NEXT: | |     `-CallExpr (0 args)
// AST-NEXT: | |       `-ChainExpr 'Self::origin'
// AST-NEXT: | |         |-NamedIdentExpr Self
// AST-NEXT: | |         `-Step ::origin
// AST-NEXT: | `-FunctionDecl  origin() -> Self
// AST-NEXT: |   `-CompoundStmt (1)
// AST-NEXT: |     `-ReturnStmt
// AST-NEXT: |       `-CallExpr (0 args)
// AST-NEXT: |         `-NamedIdentExpr Stack<T>
// AST-NEXT: |           `-GenericArg 'T'
// AST-NEXT: |-StructDecl Point
// AST-NEXT: | |-FieldDecl var x: f64
// AST-NEXT: | `-FieldDecl var y: f64
// AST-NEXT: `-ExtensionDecl Point
// AST-NEXT:   `-FunctionDecl  moved(self, dx: f64) -> Self
// AST-NEXT:     |-ParamDecl self
// AST-NEXT:     |-ParamDecl dx: f64
// AST-NEXT:     `-CompoundStmt (1)
// AST-NEXT:       `-ReturnStmt
// AST-NEXT:         `-NamedInitializerExpr
// AST-NEXT:           |-NamedIdentExpr Self
// AST-NEXT:           |-Field x
// AST-NEXT:           | `-BinaryOperatorExpr +
// AST-NEXT:           |   |-ChainExpr 'self.x'
// AST-NEXT:           |   | |-NamedIdentExpr self
// AST-NEXT:           |   | `-Step .x
// AST-NEXT:           |   `-NamedIdentExpr dx
// AST-NEXT:           `-Field y
// AST-NEXT:             `-ChainExpr 'self.y'
// AST-NEXT:               |-NamedIdentExpr self
// AST-NEXT:               `-Step .y
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// EXPECT: 0 errors. `self.items` binds to field (dependent record still looks up).
// EXPECT: `Self::origin()` step `::origin` binds; `Self` in type position canonical = Stack<T> (dependent).
class <T> Stack {
    var items: [T]

    fn Stack(self) { }

    fn push(self, v: T) {
        self.items.push(v)
    }

    fn twin(self) -> Self {
        return Self::origin()
    }

    static fn origin() -> Self {
        return Stack<T>()
    }
}

struct Point { var x: f64; var y: f64 }

extend Point {
    fn moved(self, dx: f64) -> Self {
        return Self { x: self.x + dx, y: self.y }
    }
}
