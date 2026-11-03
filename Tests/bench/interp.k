// A register-machine interpreter: ADT instructions, a match-dispatch loop.
// The program sums (i * i) % 7 for i in 0..N.
import std::io::println
ffi "c++" import "bench_env.h"

enum Inst {
    LoadI { r: i32, v: i64 },
    Mul   { d: i32, a: i32, b: i32 },
    ModI  { d: i32, a: i32, v: i64 },
    Add   { d: i32, a: i32, b: i32 },
    AddI  { d: i32, v: i64 },
    JmpLt { a: i32, b: i32, t: i32 },
    Halt,
}

fn run(prog: *[Inst; 9], regs: *[i64; 8]) {
    var pc = 0
    loop {
        match (*prog)[pc] {
            case .LoadI(var r, var v) { (*regs)[r] = v; pc += 1 }
            case .Mul(var d, var a, var b) { (*regs)[d] = (*regs)[a] * (*regs)[b]; pc += 1 }
            case .ModI(var d, var a, var v) { (*regs)[d] = (*regs)[a] % v; pc += 1 }
            case .Add(var d, var a, var b) { (*regs)[d] = (*regs)[a] + (*regs)[b]; pc += 1 }
            case .AddI(var d, var v) { (*regs)[d] += v; pc += 1 }
            case .JmpLt(var a, var b, var t) { pc = if (*regs)[a] < (*regs)[b] => t else => pc + 1 }
            case .Halt { return }
        }
    }
}

fn main() -> i32 {
    var n: i64 = bench_n()
    var prog: [Inst; 9] = [
        .LoadI { r: 0, v: 0 },            // i
        .LoadI { r: 1, v: 0 },            // acc
        .LoadI { r: 2, v: n },            // limit
        .Mul { d: 3, a: 0, b: 0 },        // t = i * i
        .ModI { d: 3, a: 3, v: 7 },       // t %= 7
        .Add { d: 1, a: 1, b: 3 },        // acc += t
        .AddI { d: 0, v: 1 },             // i += 1
        .JmpLt { a: 0, b: 2, t: 3 },      // loop while i < limit
        .Halt,
    ]
    var regs: [i64; 8] = [0, 0, 0, 0, 0, 0, 0, 0]
    run(&prog, &regs)
    println(f"{regs[1]}")
    return 0
}
