// Kairo-only types nested inside each other and inside imported templates:
// a vector of vectors of nullables, a generic ADT over a nullable and over
// a safe pointer (whose flavour survives the ADT: `Opt<*Node>`'s payload
// reads back as `*Node`, not `unsafe *Node`), a nullable pointer to a
// record, and a tuple beside them. Each stand-in nests another one.

ffi "c++" import "vector"

class Node {
    pub var id: i32
    fn Node(self, id: i32) { self.id = id }
}
enum <T> Opt { Some { v: T }, None }

fn val(o: Opt<*Node>) -> i32 = match o {
    case .Some(var v) => v->id
    default => 50
}

fn some_or(o: Opt<i32?>, d: i32) -> i32 = match o {
    case .Some(var v) => v ?? d
    default => d * 2
}

fn main() -> i32 {
    var a = Node(4)
    var n = 0

    var vv: cxx::std::vector<cxx::std::vector<i32?>>
    var row: cxx::std::vector<i32?>
    row.push_back(5)
    row.push_back(null)
    vv.push_back(row)
    vv.push_back(row)
    for r in vv { for x in r { if x? { n += x } else { n += 1 } } }   // 12

    var oo: cxx::std::vector<Opt<i32?>>
    var three: i32? = 3
    var none: i32? = null
    oo.push_back(Opt<i32?>::Some { v: three })
    oo.push_back(Opt<i32?>::Some { v: none })
    oo.push_back(Opt<i32?>::None)
    for o in oo { n += some_or(o, 1) }                    // 12 + 3 + 1 + 2 = 18

    var on: cxx::std::vector<Opt<*Node>>
    on.push_back(Opt<*Node>::Some { v: &a })
    on.push_back(Opt<*Node>::None)
    for o in on { n += val(o) }                           // 18 + 4 + 50 = 72

    var np: cxx::std::vector<cxx::std::vector<*Node?>>
    var inner: cxx::std::vector<*Node?>
    inner.push_back(&a)
    inner.push_back(null)
    np.push_back(inner)
    for r in np { for p in r { if p? { n += p->id } } }   // 76

    var tv: cxx::std::vector<(i32, i32?)>
    tv.push_back((2, three))
    for t in tv { n += t.0 + (t.1 ?? 0) }                 // 81
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 81
