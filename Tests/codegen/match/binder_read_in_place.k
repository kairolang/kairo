// A scalar `var` binder that its arm never assigns, in an arm that cannot
// write the scrutinee, is bound `const T&` to its occurrence, so the payload
// is read where it is used. An arm that stores through a pointer, calls a
// function, assigns the binder or assigns a local of a non-scalar type copies
// every binder at entry. The run checks the values each shape sees,
// including an arm that overwrites its own scrutinee and then reads a binder.
import std::io::println

enum Op {
    Jump { a: i32, b: i32, t: i32 },
    Store { d: i32, v: i64 },
    Bump { n: i32 },
    Call { x: i32 },
    Halt,
}

fn side(x: i32) -> i32 = x + 1

fn step(prog: *[Op; 6], regs: *[i64; 4], pc: i32) -> i32 {
    var next = pc
    match (*prog)[pc] {
        case .Jump(var a, var b, var t) {
            next = if (*regs)[a] < (*regs)[b] => t else => pc + 1
        } case .Store(var d, var v) {
            (*regs)[d] = v
            next       = pc + 1
        } case .Bump(var n) {
            n += 1
            next = pc + n - 1
        } case .Call(var x) {
            next = side(x)
        } case .Halt {
            next = -1
        }
    }

    return next
}

enum Cell {
    Num { v: i64 },
    Empty,
}

// The arm overwrites the scrutinee through `p`, then reads `v`: the value
// from entry.
fn through_pointer(p: *Cell) -> i64 {
    match *p {
        case .Num(var v) {
            *p = Cell::Empty
            return v
        } case .Empty {
            return -1
        }
    }
}

// The same through the local that is the scrutinee.
fn through_local(k: i64) -> i64 {
    var c = Cell::Num { v: k }
    match c {
        case .Num(var v) {
            c = Cell::Empty
            return v
        } case .Empty {
            return -1
        }
    }
}

// Value form, a guard, and a loop that writes only scalar locals.
fn pick(c: Cell, k: i64) -> i64 = match c {
    case .Num(var v) where v > 100 => v * 2
    case .Num(var v) => if v > k => v else => k
    case .Empty => 0
}

fn sum3(c: Cell) -> i64 {
    match c {
        case .Num(var v) {
            var s: i64 = 0
            var i      = 0
            while i < 3 {
                s += v
                ++i
            }

            return s
        } case .Empty {
            return 0
        }
    }
}

// A container's subscript is not a plain element read: the binder is copied.
fn first_plus(const xs: [i64], c: Cell) -> i64 {
    match c {
        case .Num(var v) {
            return xs[0] + v
        } case .Empty {
            return xs[0]
        }
    }
}

enum Mixed {
    M { b: bool, c: u8, f: f64, w: i128 },
    Z,
}

fn mixed(m: Mixed) -> i64 = match m {
    case .M(var b, var c, var f, var w) => if b => (c as i64) + (w as i64) else => f as i64
    case .Z => 0
}

// Alternatives (the binder is read through a slot) and a nested pattern.
enum Two {
    A { x: i32 },
    B { x: i32 },
    In { c: Cell, y: i32 },
}

fn alt(t: Two) -> i64 = match t {
    case .A(var x), .B(var x) => if x > 0 => x else => 0
    case .In(.Num(var v), var y) => v + (y as i64)
    case .In(.Empty, var y) => y
}

// A nested match in the arm.
fn nested(t: Two) -> i64 = match t {
    case .In(var c, var y) => match c {
        case .Num(var v) => if v > 0 => v + (y as i64) else => 0
        case .Empty => -1
    }
    default => -2
}

fn main() -> i32 {
    var prog: [Op; 6] = [
        .Store { d: 0, v: 0 },
        .Store { d: 1, v: 3 },
        .Bump { n: 1 },
        .Jump { a: 0, b: 1, t: 5 },
        .Call { x: 4 },
        .Halt,
    ]

    var regs: [i64; 4] = [0, 0, 0, 0]
    var pc             = 0
    var trace          = 0
    while pc >= 0 {
        trace = trace * 10 + pc
        pc    = step(&prog, &regs, pc)
    }

    println(f"trace {trace}")
    var cell = Cell::Num { v: 42 }
    println(f"pointer {through_pointer(&cell)} {through_pointer(&cell)}")
    println(f"local {through_local(9)}")
    println(
        f"pick {pick(Cell::Num { v: 7 }, 3)} {pick(Cell::Num { v: 2 }, 3)} {pick(Cell::Num { v: 200 }, 3)} {pick(Cell::Empty, 3)}",
    )

    println(f"sum3 {sum3(Cell::Num { v: 5 })}")
    var xs: [i64] = [30, 40]
    println(f"first {first_plus(xs, Cell::Num { v: 5 })}")
    println(
        f"mixed {mixed(Mixed::M { b: true, c: 7, f: 2.5, w: 100 })} {mixed(Mixed::M { b: false, c: 7, f: 2.5, w: 100 })}",
    )

    println(
        f"alt {alt(Two::A { x: 4 })} {alt(Two::B { x: -4 })} {alt(Two::In { c: Cell::Num { v: 10 }, y: 5 })} {alt(Two::In { c: Cell::Empty, y: 6 })}",
    )

    println(
        f"nested {nested(Two::In { c: Cell::Num { v: 10 }, y: 5 })} {nested(Two::In { c: Cell::Empty, y: 5 })} {nested(Two::A { x: 1 })}",
    )

    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR:      const signed int & a = __kairo_m0_s.__kairo_Jump.a;
// IR-NEXT: const signed int & b = __kairo_m0_s.__kairo_Jump.b;
// IR-NEXT: const signed int & t = __kairo_m0_s.__kairo_Jump.t;
// IR:      signed int d = __kairo_m0_s.__kairo_Store.d;
// IR-NEXT: signed {{long|long long}} v = __kairo_m0_s.__kairo_Store.v;
// IR:      signed int n = __kairo_m0_s.__kairo_Bump.n;
// IR:      signed int x = __kairo_m0_s.__kairo_Call.x;
// IR-LABEL: through_pointer({{.*}}) noexcept {
// IR:      signed {{long|long long}} v = __kairo_m0_s.__kairo_Num.v;
// IR-LABEL: through_local({{.*}}) noexcept {
// IR:      signed {{long|long long}} v = __kairo_m0_s.__kairo_Num.v;
// IR-LABEL: sum3({{.*}}) noexcept {
// IR:      const signed {{long|long long}} & v = __kairo_m0_s.__kairo_Num.v;
// IR-LABEL: first_plus({{.*}}) noexcept {
// IR:      signed {{long|long long}} v = __kairo_m0_s.__kairo_Num.v;
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d/o2
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT-LABEL: trace 1235
// OUT-NEXT: pointer 42 -1
// OUT-NEXT: local 9
// OUT-NEXT: pick 7 3 400 0
// OUT-NEXT: sum3 15
// OUT-NEXT: first 35
// OUT-NEXT: mixed 107 2
// OUT-NEXT: alt 4 0 15 6
// OUT-NEXT: nested 15 -1 -2
