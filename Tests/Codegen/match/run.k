@open enum Level { Debug, Info, Warn, Error, Fatal }

struct Point { var x: i32; var y: i32; }

fn level(l: Level) -> i32 = match l {
    case .Debug => 1
    case .Info  => 2
    case .Warn  => 4
    case .Error => 8
    case .Fatal => 16
}

fn status(code: i32) -> i32 = match code {
    case 200       => 1
    case 1, 2, 3   => 2
    case 300..400  => 3
    case 400..=499 => 4
    default        => 0
}

fn word(s: string) -> i32 = match s {
    case "a"   => 1
    case "abc" => 2
    case "xyz" => 3
    case ""    => 4
    default    => 0
}

fn pair(a: i32, b: i32) -> i32 = match (a, b) {
    case (0, 0)     => 1
    case (0, var y) => 10 + y
    case (var x, 0) => 20 + x
    default         => 99
}

fn guarded(x: i32, c: bool) -> i32 = match x {
    case 1 where c => 10
    case 1         => 11
    default        => 0
}

fn point(p: Point) -> i32 = match p {
    case Point(var x, 0) => x
    case Point(0, var y) => 100 + y
    default              => -1
}

fn flag(b: bool) -> i32 = match b {
    case true  => 7
    case false => 3
}

fn stmt_form(x: i32) -> i32 {
    var acc: i32 = 0
    match x {
        case 1  { acc = 5; }
        case 2  { acc = 6; }
        default { acc = 9; }
    }
    return acc
}

// Arm bodies sit outside the dispatch switch: `break` and `continue` reach the loop.
fn loop_arms(xs: [i32;]) -> i32 {
    var acc: i32 = 0
    for x in xs {
        match x {
            case -1 { break; }
            case 0  { continue; }
            default { acc += x; }
        }
    }
    return acc
}

fn labeled() -> i32 {
    var n: i32 = 0
    outer: for i in 0..10 {
        for j in 0..10 {
            if j == 3 { continue outer }
            if i == 4 { break outer }
            n += 1
        }
    }
    return n
}

fn main() -> i32 {
    var t: i32 = 0
    t += level(Level::Debug) + level(Level::Info) + level(Level::Warn) + level(Level::Error) + level(Level::Fatal)  // 31
    t += status(200) + status(2) + status(350) + status(450) + status(500)                                          // 10
    t += word("a") + word("abc") + word("xyz") + word("") + word("zz")                                              // 10
    t += pair(0, 0) + pair(0, 5) + pair(7, 0) + pair(1, 1)                                                          // 142
    t += guarded(1, true) + guarded(1, false) + guarded(2, true)                                                    // 21
    t += point(Point { x: 3, y: 0 }) + point(Point { x: 0, y: 4 }) + point(Point { x: 1, y: 1 })                    // 106
    t += flag(true) + flag(false)                                                                                   // 10
    t += stmt_form(1) + stmt_form(2) + stmt_form(7)                                                                 // 20
    var sl: [i32;] = [3, 0, 4, -1, 100]
    t += loop_arms(sl)                                                                                              // 7
    t += labeled()                                                                                                  // 12
    return t - 300                                                                                                  // 369 - 300 == 69
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-DAG: signed int __kairo_m0_s = code;
// IR-DAG: default: __builtin_trap();
// IR-DAG: case 300 ... 399: goto __kairo_m0_t{{[0-9]+}};
// IR-DAG: switch(__kairo_m0_s.len) {
// IR-DAG: __builtin_memcmp(static_cast<const void *>(__kairo_m0_s.data), static_cast<const void *>("abc"), 3) == 0
// IR-DAG: goto __kairo_brk{{[0-9]+}}_outer;
// IR-DAG: goto __kairo_cont{{[0-9]+}}_outer;
// IR-DAG: __kairo_brk{{[0-9]+}}_outer:;
// IR-DAG: case 0: goto __kairo_m{{[0-9]+}}_{{[at][0-9]+}};

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 69
