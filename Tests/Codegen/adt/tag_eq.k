// `==` on an ADT enum that declares no `op ==` compares the tags alone: two
// values of one variant are equal whatever their payloads, values of two
// variants are not, and `!=` is the negation. It is a comparison of the two
// tag fields, so no `operator==` is looked up in C++ -- not even inside
// Pair's own `op ==`, where a member of that name is in scope. An enum that
// extends its own `op ==` keeps it: Cell's says no two cells are equal,
// which the tags would contradict. Each operand is evaluated once.

var calls: i32 = 0

enum <T> Opt { Some { v: T }, None }
enum Shape { Circle { r: i32 }, Rect { w: i32, h: i32 }, Empty }
enum Cell { Full { n: i32 }, Blank }

extend Cell {
    fn op ==(const self, const other: Cell) -> bool { return false }
}

extend Shape {
    fn same_kind(self, other: Shape) -> bool { return self == other }
}

struct Pair {
    var a: Opt<i32>
    var b: Opt<i32>
    fn op ==(self, other: Pair) -> bool { return (self.a == other.a) && (self.b == other.b) }
}

fn next() -> Opt<i32> {
    calls = calls + 1
    return Opt<i32>::Some { v: calls }
}

fn main() -> i32 {
    var a = Opt<i32>::Some { v: 1 }
    var b = Opt<i32>::Some { v: 2 }
    var n: Opt<i32> = .None
    var c = Shape::Circle { r: 1 }
    var d = Shape::Circle { r: 9 }
    var e = Shape::Empty
    var f = Cell::Full { n: 1 }
    var p = Pair { a: a, b: n }
    var q = Pair { a: b, b: n }
    var r = 0
    if (a == b) && (!(a != b))            { r += 1 }     // the payloads differ, the tags match
    if (!(a == n)) && (a != n)            { r += 2 }
    if c == d                             { r += 4 }
    if (c != e) && (Shape::Empty == e)    { r += 8 }     // a temporary as an operand
    if c.same_kind(d) && (!e.same_kind(c)) { r += 16 }   // `self` as an operand
    if (!(f == f)) && (f != f)            { r += 32 }    // Cell's own, and `!=` from it
    if p == q                             { r += 64 }    // Pair's own, over two tag `==`
    if (next() == next()) && (calls == 2) { r += 100 }   // each operand runs once
    return r                                             // 227
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The tag is a public member of each record: the compares read it from
// outside the class. Shape's payloads are all integers, so its tag lives in
// their common prefix and is read through the union's tag-only member.
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}tag_eq.k
// CXX:       template<class T> struct Opt {
// CXX-NOT:   {{private|protected}}
// CXX:       __kairo_Tag __kairo_tag;
// CXX:       struct Shape {
// CXX-NOT:   {{private|protected}}
// CXX:       __kairo_t_t __kairo_t;

// Every tag `==` is a compare of two tag fields -- through `self` in an
// extension, through `this` inside Pair's own operator, on a temporary and
// on two calls -- and Cell's goes through its own operator.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}tag_eq.k
// IR-DAG:    self->__kairo_t.__kairo_tag == other.__kairo_t.__kairo_tag
// IR-DAG:    this->a.__kairo_tag == other.a.__kairo_tag
// IR-DAG:    this->b.__kairo_tag == other.b.__kairo_tag
// IR-DAG:    a.__kairo_tag != n.__kairo_tag
// IR-DAG:    ).__kairo_t.__kairo_tag == e.__kairo_t.__kairo_tag
// IR-DAG:    next().__kairo_tag == {{.*}}next().__kairo_tag
// IR-DAG:    __kairo_ext_Cell::__kairo_op_eq(f, f)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 227
