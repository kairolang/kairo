// An `eval` constant of an ADT enum type is a C++ `constexpr` variable, so
// the ADT must be a literal type there: its variant constructors are
// `constexpr` when the variants' fields are trivial (the prefix-tagged
// layout). They are plain, so clang accepts the constant (no CL001E
// "constexpr variable cannot have non-literal type").

enum Shape {
    Circle { r: i32 },
    Square { s: i32 },
    Dot,
}

eval UNIT: Shape = Shape::Circle { r: 3 }
eval SIDE: Shape = Shape::Square { s: 4 }
eval NONE: Shape = Shape::Dot

fn size(sh: Shape) -> i32 {
    match sh {
        case .Circle(var r) { return r }
        case .Square(var s) { return s * 10 }
        case .Dot { return 100 }
    }
}

fn main() -> i32 {
    return size(UNIT) + size(SIDE) + size(NONE) // 3 + 40 + 100
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 143
