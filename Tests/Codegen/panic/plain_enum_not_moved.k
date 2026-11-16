// A payload-free enum is a C++ `enum class`: a local of one is read, not
// cast to `E &&`, where lowering moves a class object out of a local. Three
// places do: a returned local of a panicking function (`pick`), a payload
// field computed ahead of the payload because it can leave the function
// (`built`), and one computed ahead because the fields are written out of
// order (`ordered`). An ADT enum in the same place is a class object and
// is still moved (`shape`).
struct E { var c: i32 }
enum Color { Red, Green }
enum Shape { Dot, Rect { w: i32, h: i32 } }
enum Pair { None, Two { c: Color, n: i32 } }

fn pick(f: bool) panic(E) -> Color {
    if f { panic E { c: 1 } }
    var chosen = Color::Green
    return chosen
}
fn shape(f: bool) panic(E) -> Shape {
    if f { panic E { c: 1 } }
    var s = Shape::Rect { w: 1, h: 2 }
    return s
}
fn side(f: bool) panic(E) -> i32 { if f { panic E { c: 1 } } return 1 }
fn col(f: bool) panic(E) -> Color { if f { panic E { c: 1 } } return Color::Red }
fn built(f: bool) panic(E) -> Pair {
    return Pair::Two { c: col(f), n: side(f) }
}
fn plain_col() -> Color { return Color::Green }
fn plain_n() -> i32 { return 2 }
fn ordered() -> Pair {
    return Pair::Two { n: plain_n(), c: plain_col() }
}
fn main() -> i32 {
    var a = try pick(false) catch => Color::Red
    if a != Color::Green { return 1 }
    var s = try shape(false) catch => Shape::Dot
    var p = try built(false) catch => Pair::None
    var q = ordered()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-ir -c -o /dev/null --emit-scope=inputs | %FileCheck %s
// CHECK-NOT: Color &&>(chosen)
// CHECK-NOT: Color &&>(__kairo_v
// CHECK-NOT: Color &&>(__kairo_ord
// CHECK: static_cast< ::plain_enum_not_moved::Shape &&>(s)
// CHECK-NOT: Color &&>(chosen)
// CHECK-NOT: Color &&>(__kairo_v
// CHECK-NOT: Color &&>(__kairo_ord
