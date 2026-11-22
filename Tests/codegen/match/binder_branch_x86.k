// A dispatch loop whose arm picks the next index from a payload
// (`pc = if c => t else => pc + 1`) keeps that choice a branch at -O3: the
// binder `t` is read at its use (codegen/match/binder_read_in_place.k), so
// clang cannot fold the arm into a select, and the next iteration's load of
// `prog[pc]` does not wait on the comparison through a cmov.
import std::io::println

enum Inst {
    Set { r: i32, v: i64 },
    AddI { d: i32, v: i64 },
    JmpLt { a: i32, b: i32, t: i32 },
    Halt,
}

fn dispatch(prog: *[Inst; 5], regs: *[i64; 4]) {
    var pc = 0
    loop {
        match (*prog)[pc] {
            case .Set(var r, var v) {
                (*regs)[r] = v
                pc += 1
            } case .AddI(var d, var v) {
                (*regs)[d] += v
                pc += 1
            } case .JmpLt(var a, var b, var t) {
                pc = if (*regs)[a] < (*regs)[b] => t else => pc + 1
            } case .Halt {
                return
            }
        }
    }
}

fn main() -> i32 {
    var prog: [Inst; 5] = [
        .Set { r: 0, v: 0 },
        .Set { r: 1, v: 10 },
        .AddI { d: 0, v: 1 },
        .JmpLt { a: 0, b: 1, t: 2 },
        .Halt,
    ]

    var regs: [i64; 4] = [0, 0, 0, 0]
    dispatch(&prog, &regs)
    println(f"{regs[0]}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, llvm-objdump, host-x86_64
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -O3 -o %t.exe --cache-dir %t.d/exe
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 10
// RUN: %kairo %s -c -O3 --cache-dir %t.d/o3
// RUN: %objdump --show-all-symbols -d --no-show-raw-insn %t.d/o3/binder_branch_x86.o > %t.s
// RUN: awk '/<[^>]*8dispatch[^>]*>:/,/^$/' %t.s > %t.fn.s
// RUN: grep -q 'jmp' %t.fn.s
// RUN: { ! grep -q 'cmov' %t.fn.s; }
