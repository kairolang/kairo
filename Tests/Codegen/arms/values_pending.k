enum Level { Debug, Info, Error }

fn pick(c: i32) -> i32 = if c == 0 => 10 else if c > 5 => 20 else => 30

fn lv(l: Level) -> i32 = match l {
    case .Debug => 1
    case .Info  => 2
    case .Error => 4
}

fn risky(x: i32) panic -> i32 {
    if x < 0 { panic 1; }
    return x;
}

fn safe(x: i32) -> i32 = try risky(x) catch => 100

// The multi-line layouts of the two forms that cannot run yet.
fn lv_split(l: Level) -> i32 = match l {
    case .Debug
    => 1
    case .Info =>
    2
    case .Error => 4
}

fn safe_split(x: i32) -> i32 = try risky(x)
    catch => 100

fn main() -> i32 {
    var a = pick(0) + pick(9) + pick(3)                             // 10 + 20 + 30 = 60
    var b = lv(Level::Debug) + lv(Level::Info) + lv(Level::Error)   // 7
    var c = safe(5) + safe(-1)                                      // 105
    var d = f2(if a > 0 => 1 else => 0, 2)                          // 3
    var e = lv_split(Level::Info) + safe_split(-1) - 102            // 0
    return a + b + c + d + e - 165                                  // 10
}

fn f2(x: i32, y: i32) -> i32 = x + y

// --- lit wiring -----------------------------------------------------------
// The full §9.4 program: `match` and `try` value arms next to `if`. It
// type-checks clean today. It does not run yet: EmitIR has no lowering for a
// match expression ("MatchLowering owns it") or for `panic` ("PanicLowering
// owns it"), so codegen ICEs before a binary exists.
//
// TODO(MatchLowering, PanicLowering): once both land, link and run this file
// like values.k and expect exit code 10.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
