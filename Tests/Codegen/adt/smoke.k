// An ADT enum is a C++ struct: a tag, the payloads in an anonymous union, a
// constructor per variant and the special members the payloads allow. Each
// kind here is built, matched, copied, assigned across tags and destroyed:
// a non-generic enum over integers (every special member defaulted), a
// non-generic one owning a class with a destructor (every one with a body),
// and a generic one at a trivial and at an owning argument (all three forms
// of each, the constraints selecting one). Res counts its destructions, so
// a payload destroyed twice, or never, shows in the exit code.

var drops: i32 = 0

class Res {
    pub var id: i32
    pub fn Res(self, id: i32) { self.id = id; }
    @copy fn Res(self, const other: Self) = default
    fn op delete(self) { drops = drops + 1; }
}

enum Shape { Circle { r: i32 }, Rect { w: i32, h: i32 }, Empty }
enum Held { Full { r: Res, n: i32 }, Vacant }
enum <T> Opt { Some { v: T }, None }

fn area(s: Shape) -> i32 {
    match s {
        case .Circle(var r)      { return 3 * r * r; }
        case .Rect(var w, var h) { return w * h; }
        case .Empty              { return 0; }
    }
}

fn get(o: Opt<i32>) -> i32 {
    return match o {
        case .Some(var v) => v
        case .None => -1
    }
}

fn held_n(const h: Held) -> i32 {
    match h {
        case .Full(const r, var n) { return r.id + n; }
        case .Vacant               { return 0; }
    }
}

fn get_id(const p: Opt<Res>) -> i32 {
    return match p {
        case .Some(const v) => v.id
        case .None => 0
    }
}

// One Res is built in place, a second by the copy, a third by the copy
// assignment back into the vacated b; assigning Vacant destroys the second,
// and the two left die at the end: three drops.
fn lifecycle() -> i32 {
    var a = Held::Full { r: Res(5), n: 4 }
    var b = a
    b = Held::Vacant
    b = a
    return held_n(b)
}

// The copy assignment builds a second Res in p and assigning None destroys
// the first; p's dies at the end: two drops.
fn generic_scope() -> i32 {
    var o = Opt<Res>::Some { v: Res(2) }
    var p: Opt<Res> = .None
    p = o
    o = Opt<Res>::None
    return get_id(p)
}

fn main() -> i32 {
    var t = area(Shape::Rect { w: 2, h: 3 })    // 6
    t += area(Shape::Circle { r: 1 })           // 3
    t += area(Shape::Empty)                     // 0
    t += get(Opt<i32>::Some { v: 7 })           // 7
    t += get(Opt<i32>::None)                    // -1
    t += lifecycle()                            // 9
    t += generic_scope()                        // 2
    return t + drops * 10                       // 26 + 5 * 10 == 76
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 76
