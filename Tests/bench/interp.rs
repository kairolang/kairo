// See interp.k.
#[derive(Clone, Copy)]
enum Inst {
    LoadI { r: usize, v: i64 },
    Mul { d: usize, a: usize, b: usize },
    ModI { d: usize, a: usize, v: i64 },
    Add { d: usize, a: usize, b: usize },
    AddI { d: usize, v: i64 },
    JmpLt { a: usize, b: usize, t: usize },
    Halt,
}

fn run(prog: &[Inst; 9], regs: &mut [i64; 8]) {
    let mut pc = 0;
    loop {
        match prog[pc] {
            Inst::LoadI { r, v } => { regs[r] = v; pc += 1 }
            Inst::Mul { d, a, b } => { regs[d] = regs[a].wrapping_mul(regs[b]); pc += 1 }
            Inst::ModI { d, a, v } => { regs[d] = regs[a] % v; pc += 1 }
            Inst::Add { d, a, b } => { regs[d] = regs[a].wrapping_add(regs[b]); pc += 1 }
            Inst::AddI { d, v } => { regs[d] = regs[d].wrapping_add(v); pc += 1 }
            Inst::JmpLt { a, b, t } => { pc = if regs[a] < regs[b] { t } else { pc + 1 } }
            Inst::Halt => return,
        }
    }
}

fn main() {
    let n: i64 = std::env::var("N").unwrap().parse().unwrap();
    use Inst::*;
    let prog = [
        LoadI { r: 0, v: 0 }, LoadI { r: 1, v: 0 }, LoadI { r: 2, v: n },
        Mul { d: 3, a: 0, b: 0 }, ModI { d: 3, a: 3, v: 7 }, Add { d: 1, a: 1, b: 3 },
        AddI { d: 0, v: 1 }, JmpLt { a: 0, b: 2, t: 3 }, Halt,
    ];
    let mut regs = [0i64; 8];
    run(&prog, &mut regs);
    println!("{}", regs[1]);
}
