// `op []=`, the place form of the subscript, is an operator name
// wherever an operator can be declared: a class body, a struct body, an
// `extend` block (Sema rejects it there: it is member-only, as `op []` is),
// an interface, an out-of-line definition, and the generic forms (the
// tree printer shows no struct members; the struct's operator is checked
// by Tests/Sema/Operators/subscript_split_signatures.k). It is
// three tokens, `[` `]` `=`, with the `=` touching the `]`: no lexer token,
// so `a[i]= 5` in an expression still reads as an assignment. Written with a
// space (`op [] =`) it is S045E with a fix-it closing the gap, and is still
// read as `op []=`, so nothing after it cascades. An explicit call names it
// as any operator step does (`b.op []=(1)`).

class Buf {
    var d: [i32; 4]
    fn Buf(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
}

struct Pair {
    var a: [i32; 2]
    fn op []= (self, i: usize) -> *i32 { return &self.a[i] }
}

class <T> Box {
    var d: [T; 2]
    fn Box(self) { }
    fn op []= (self, i: usize) -> *T { return &self.d[i] }
    fn <K> op []= (self, k: K) -> *T { return &self.d[0] }
}

interface Store {
    fn op []= (self, i: usize) -> *i32
}

class Late {
    var d: [i32; 2]
    fn Late(self) { }
    fn op []= (self, i: usize) -> *i32
}

fn Late::op []= (self, i: usize) -> *i32 { return &self.d[i] }

extend Buf {
    fn op []= (self, i: i64) -> *i32 { return &self.d[0] }
}

class Spaced {
    var d: [i32; 2]
    fn Spaced(self) { }
    fn op [] = (self, i: usize) -> *i32 { return &self.d[i] }
}

fn use_it() {
    var b = Buf()
    var p = b.op []=(1)
    var a: [i32; 2] = [1, 2]
    a[0]= 5
}

// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST:      FunctionDecl  op [] (const self, i: usize) -> *const i32
// AST:      FunctionDecl  op []= (self, i: usize) -> *i32
// AST:      ClassDecl Box
// AST:      FunctionDecl  op []= (self, i: usize) -> *T
// AST:      FunctionDecl <K> op []= (self, k: K) -> *T
// AST:      InterfaceDecl Store
// AST:      FunctionDecl  op []= (self, i: usize) -> *i32
// AST:      FunctionDecl  op []= (self, i: usize) -> *i32
// AST:      FunctionDecl {{.*}}op []= (self, i: usize) -> *i32
// AST:      ExtensionDecl Buf
// AST:      FunctionDecl  op []= (self, i: i64) -> *i32
// AST:      ClassDecl Spaced
// AST:      FunctionDecl  op []= (self, i: usize) -> *i32
// AST:      Step .op[]=
// AST:      AssignOperatorExpr
// AST-NEXT: SubscriptExpr

// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:     op_subscript_set.k:51:14: error [S045E]: the place subscript operator is spelled 'op []=', with no space before '='
// DIAG:     fix-it:{{.*}}:{51:13-51:14}:""
// DIAG-NOT: error
