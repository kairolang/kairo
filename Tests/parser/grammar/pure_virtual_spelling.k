// A pure virtual method is a `virtual fn` with no body. `= virtual`, the
// old spelling, is S047E with fix-its that rewrite it: remove `= virtual`,
// and insert `virtual ` before the method when it is not already virtual.
// Recovery reads it as pure virtual, so nothing cascades. After `=` a
// function takes only an expression, `default` or `delete`. In the tree a
// pure method is tagged `pure`; a bodyless method that is not virtual is a
// declaration, not pure.

class Shape {
    fn area(const self) -> i32 = virtual
    virtual fn sides(const self) -> i32 = virtual
    virtual fn name(const self) -> i32
    fn plain(const self) -> i32 = 3
    fn decl_only(const self) -> i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: pure_virtual_spelling.k:10:34: error [S047E]: '= virtual' is not a function body; a pure virtual method is a 'virtual fn' with no body
// DIAG-NEXT: fix-it:"{{.*}}pure_virtual_spelling.k":{10:31-10:41}:""
// DIAG-NEXT: fix-it:"{{.*}}pure_virtual_spelling.k":{10:5-10:5}:"virtual "
// DIAG-NEXT: pure_virtual_spelling.k:11:43: error [S047E]: '= virtual' is not a function body; a pure virtual method is a 'virtual fn' with no body
// DIAG-NEXT: fix-it:"{{.*}}pure_virtual_spelling.k":{11:40-11:50}:""
// DIAG-NOT: fix-it
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=TREE
// TREE-LABEL: TranslationUnit '{{.*}}pure_virtual_spelling.k'(fid=0)
// TREE-NEXT: `-ClassDecl Shape
// TREE-NEXT:   |-FunctionDecl  area(const self) -> i32 pure
// TREE-NEXT:   | `-ParamDecl const self
// TREE-NEXT:   |-FunctionDecl  sides(const self) -> i32 pure
// TREE-NEXT:   | `-ParamDecl const self
// TREE-NEXT:   |-FunctionDecl  name(const self) -> i32 pure
// TREE-NEXT:   | `-ParamDecl const self
// TREE-NEXT:   |-FunctionDecl  plain(const self) -> i32
// TREE-NEXT:   | |-ParamDecl const self
// TREE-NEXT:   | `-IntegerLiteralExpr 3
// TREE-NEXT:   `-FunctionDecl  decl_only(const self) -> i32
// TREE-NEXT:     `-ParamDecl const self
