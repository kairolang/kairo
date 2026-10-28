// Functions, classes, structs and enums declared in a function body, in the
// shapes codegen has to tell apart. Each is emitted at namespace scope under
// a name that carries its position (CXXSpell::is_hoisted_local), so two
// functions' locals of one name and two sibling blocks' coexist; a local fn
// is a value like any other; a local class keeps its constructors, methods
// and field defaults; a local ADT keeps its payloads and `match`.

fn twice(x: i32) -> i32 { return x * 2 }

fn first() -> i32 {
    fn helper() -> i32 { return 1 }
    return helper()
}

fn second() -> i32 {
    fn helper() -> i32 { return 2 }                 // same name, other function
    return helper()
}

fn recursion() -> i32 {
    fn fact(n: i32) -> i32 {
        if n <= 1 { return 1 }
        return n * fact(n - 1)
    }
    return fact(4)                                  // 24
}

fn calls_outer() -> i32 {
    fn quad(x: i32) -> i32 { return twice(twice(x)) }   // a file-scope fn
    return quad(3)                                  // 12
}

fn as_value() -> i32 {
    fn pick(x: i32) -> i32 { return x + 100 }
    var f: fn(i32) -> i32 = pick                    // a local fn is a value too
    return f(5) + pick(2)                           // 105 + 102
}

fn blocks(c: bool) -> i32 {
    var r = 0
    if c {
        fn inner() -> i32 { return 10 }
        r += inner()
    }
    {
        fn inner() -> i32 { return 20 }             // a sibling block's
        r += inner()
    }
    return r                                        // 30
}

fn nested() -> i32 {
    fn outer_local(x: i32) -> i32 {
        fn inner_local(y: i32) -> i32 { return y + 1 }
        return inner_local(x) * 2
    }
    return outer_local(4)                           // 10
}

fn with_class() -> i32 {
    class Counter {
        pub var n: i32 = 5
        fn Counter(self) { }
        fn Counter(self, start: i32) { self.n = start }
        fn bump(self, by: i32) -> i32 { self.n += by  return self.n }
        fn get(const self) -> i32 { return self.n }
    }
    var a = Counter()
    var b = Counter(10)
    a.bump(2)
    return a.get() + b.bump(1)                      // 7 + 11
}

fn with_struct() -> i32 {
    struct Pt { var x: i32; var y: i32 }
    fn sum(p: Pt) -> i32 { return p.x + p.y }       // a local type in a local fn
    fn make(a: i32) -> Pt { return Pt { x: a, y: a + 1 } }
    return sum(make(3))                             // 7
}

fn with_enum() -> i32 {
    enum Color { Red, Green, Blue }
    var c = Color::Blue
    if c == Color::Blue { return 3 }
    return 0
}

fn with_adt() -> i32 {
    enum Shape { Circle { r: i32 }, Rect { w: i32, h: i32 }, Empty }
    fn area(s: Shape) -> i32 {
        return match s {
            case .Circle(const r)        => 3 * r * r
            case .Rect(const w, const h) => w * h
            case .Empty                  => 0
        }
    }
    return area(Shape::Rect { w: 2, h: 5 }) + area(Shape::Circle { r: 1 }) + area(Shape::Empty)   // 10 + 3
}

class Holder {
    pub var base: i32 = 40
    fn method(self) -> i32 {
        fn add(a: i32, b: i32) -> i32 { return a + b }
        class Tmp { pub var v: i32 = 2 }
        var t = Tmp()
        return add(self.base, t.v)                  // 42
    }
}

fn main() -> i32 {
    var n = 0
    if first() == 1                { n += 1 }
    if second() == 2               { n += 1 }
    if recursion() == 24           { n += 1 }
    if calls_outer() == 12         { n += 1 }
    if as_value() == 207           { n += 1 }
    if blocks(true) == 30          { n += 1 }
    if nested() == 10              { n += 1 }
    if with_class() == 18          { n += 1 }
    if with_struct() == 7          { n += 1 }
    if with_enum() == 3            { n += 1 }
    if with_adt() == 13            { n += 1 }
    var h = Holder()
    if h.method() == 42            { n += 1 }
    return n                                        // 12
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 12
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
