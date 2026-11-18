// A plain Kairo enum as an imported template's argument: `vector<Color>`,
// and as a `map` key, which C++ orders with the enum's own `<`. Phase A's
// stand-in is a scoped enum of the enum's word (`derives u8` here, u32 by
// default), under the name EmitIR gives it, and the fill reads it back as
// the Kairo enum, so its variants compare and convert as usual.

ffi "c++" import "vector"
ffi "c++" import "map"

enum Color derives u8 { Red, Green, Blue }
enum Dir { North, South }

fn weight(c: Color) -> i32 {
    if c == Color::Blue { return 5 }
    if c == Color::Green { return 2 }
    return 1
}

fn main() -> i32 {
    var v: cxx::std::vector<Color>
    v.push_back(Color::Green)
    v.push_back(Color::Blue)
    v.push_back(Color::Red)
    var n = 0
    for c in v { n += weight(c) }                         // 8
    if v[1] == Color::Blue { n += 10 }                    // 18
    if v.back() == Color::Red { n += 100 }                // 118

    var m: cxx::std::map<Color, i32>
    m[Color::Blue] = 7
    m[Color::Red] = 3
    m[Color::Blue] += 1
    n += m[Color::Blue] + m.at(Color::Red)                // 129
    n += (m.size() as i32) * 1000                         // 2129

    var d: cxx::std::vector<Dir>
    d.push_back(Dir::South)
    if d[0] == Dir::South { n += 10000 }                  // 12129
    return n - 12100                                      // 29
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 29
