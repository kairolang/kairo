// RUN: { %kairo %s --preserve-comments --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s
// Each declaration carries exactly the comment run directly above it.
// The banner at the top is cut off by a blank line and belongs to nothing.
// CHECK: |-FunctionDecl pub   first() -> i32
// CHECK-NEXT: | |-Attribute /// doc-comment
// CHECK-NEXT: | |-Attribute /// doc-comment
// CHECK-NEXT: | `-CompoundStmt
// CHECK: |-ClassDecl pub  Point
// CHECK-NEXT: | |-Attribute /// doc-comment
// CHECK-NEXT: | |-FieldDecl pub  var x: i32
// CHECK-NEXT: | | `-Attribute /// doc-comment
// CHECK-NEXT: | `-FunctionDecl pub   m(self) -> i32
// CHECK-NEXT: |   |-Attribute /// doc-comment
// CHECK-NEXT: |   |-ParamDecl self
// CHECK: |-FunctionDecl pub   second() -> i32
// CHECK-NEXT: | |-Attribute /// doc-comment
// CHECK-NEXT: | |-Attribute @cold_path
// CHECK: FunctionDecl  undocumented() -> i32
// CHECK-NEXT: `-CompoundStmt
// CHECK-NOT: line-comment

// Banner line 1
// Banner line 2

/// first doc
/// first doc, second line
pub fn first() -> i32 { return 1 }

/// class doc
pub class Point {
    /// field doc
    pub var x: i32

    /// method doc
    pub fn m(self) -> i32 { return 0 }
}

/// second doc
@cold_path
pub fn second() -> i32 { return 2 }

fn undocumented() -> i32 { return 3 }
