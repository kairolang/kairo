// build: kairo F25-no-synthesized-repr.k   (expect "Point { x: 1, y: 2 }" and "Green")
import std::io

struct Point {
    var x: i32
    var y: i32
}

enum Color { Red, Green, Blue }

fn main() -> i32 {
    var p = Point { x: 1, y: 2 }
    var c: Color = .Green
    io::println(f"{p}")
    io::println(f"{c}")
    return 0
}
