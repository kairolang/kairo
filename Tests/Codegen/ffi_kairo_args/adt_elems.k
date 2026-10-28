// Kairo ADTs as an imported template's arguments: a non-generic one in a
// `vector`, a generic one's instance as a `map` value, and one whose
// payload is non-trivial (a `string`). Phase A's stand-in is the ADT's tag
// word followed by its payload fields, so it copies exactly when the real
// record does; the fill reads every member type back as the Kairo ADT,
// which then matches as usual.
//
// `map::operator[]` is not used: it default-constructs the value, and a
// Kairo ADT has no default (C++ rejects it, as for any type without one).

ffi "c++" import "vector"
ffi "c++" import "map"

enum Shape { Circle { r: i32 }, Square { s: i32 }, Empty }
enum <T> Opt { Some { v: T }, None }
enum Msg { Text { s: string }, Num { n: i32 } }

fn area(s: Shape) -> i32 = match s {
    case .Circle(var r) => r * 3
    case .Square(var s) => s * s
    default => 0
}

fn get(o: Opt<i32>) -> i32 = match o {
    case .Some(var v) => v
    default => 100
}

fn size_of(m: Msg) -> i32 = match m {
    case .Text(var s) => s.len as i32
    case .Num(var n) => n
}

fn main() -> i32 {
    var v: cxx::std::vector<Shape>
    v.push_back(Shape::Circle { r: 2 })
    v.push_back(Shape::Square { s: 3 })
    v.push_back(.Empty)
    var n = 0
    for s in v { n += area(s) }                           // 6 + 9 + 0 = 15
    n += area(v[1])                                       // 24

    var m: cxx::std::map<i32, Opt<i32>>
    m.insert_or_assign(1, Opt<i32>::Some { v: 7 })
    m.insert_or_assign(2, Opt<i32>::None)
    n += get(m.at(1)) + get(m.at(2))                      // 131

    var ms: cxx::std::vector<Msg>
    ms.push_back(Msg::Text { s: "abcd" })
    ms.push_back(Msg::Num { n: 2 })
    var copy = ms                                         // the vector copies: Msg does
    for x in copy { n += size_of(x) }                     // 137
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 137
