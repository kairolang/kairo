// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// A KAIRO record as a C++ template argument. Filling `vector<S>` asks clang
// for the specialization, which needs `S` spelled in the header's AST, and
// that AST has never heard of a Kairo type. Before TypeExport's stand-ins the
// fill failed on that argument, lookup fell back to the dependent pattern, and
// `size_type` came out opaque: `i < x.size()` found no `<` for `u64` and the
// opaque type, and `at(i)` had no viable candidate.
//
// Each shape below is one a stand-in has to get right: a plain struct, one
// whose field points back at itself (declared while the stand-in is still
// being defined), one whose field is another Kairo record (a second stand-in
// made from inside the first), and a Kairo record nested inside an instance.

ffi "c++" import "vector"

struct S {
    var v: i32
    fn S(self, x: i32) { self.v = x }
}

extend S {
    fn G(self) -> i32 { return self.v }
}

struct Node { var v: i32; var next: *Node }
struct Inner { var a: i32 }
struct Outer { var i: Inner; var b: u8 }

fn plain() -> i32 {
    var x: cxx::std::vector<S>
    x.push_back(S(10))
    var sum: i32 = 0
    for var i: u64 = 0; i < x.size(); i++ {
        sum += x.at(i).G()
    }
    return sum
}

fn shapes() -> i32 {
    var a: cxx::std::vector<Node>
    var b: cxx::std::vector<Outer>
    var c: cxx::std::vector<cxx::std::vector<Inner>>
    var node_v = a.at(0).v
    var inner_a = b.at(0).i.a
    var deep_a = c.at(0).at(0).a
    var n: u64 = a.size() + b.size() + c.size()
    return node_v + inner_a + deep_a
}

// DIAG-NOT: error

// `at` resolves and returns the Kairo record itself, so `.G` is S's
// extension method, not a member of some foreign type.
// SEMA-DAG: .size {{.*}}-> fn size
// SEMA-DAG: .at {{.*}}-> fn at
// SEMA-DAG: .G {{.*}}-> fn G
// SEMA-DAG: CallExpr {{.*}}: S&
// SEMA-DAG: CallExpr {{.*}}: Node&
// SEMA-DAG: CallExpr {{.*}}: Outer&
// SEMA-DAG: CallExpr {{.*}}: Inner&
// SEMA-DAG: node_v : i32
// SEMA-DAG: inner_a : i32
// SEMA-DAG: deep_a : i32
// SEMA-NOT: <ffi type>
