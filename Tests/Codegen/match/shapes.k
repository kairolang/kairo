enum Level { Debug, Info, Warn, Error, Fatal }

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
    default    => 0
}

fn main() -> i32 = level(Level::Info) + status(200) + word("abc")

// --- lit wiring -----------------------------------------------------------
// -O2 shapes. An open_tail enum: one bounds check and a trap -- `ud2` on
// x86, `brk` on arm64 -- (UnmatchedPolicy Trap), gone at -O3 (Unreachable).
// Ranges: a switch, so a binary search or table, never the linear compare
// chain an if-chain of ranges stays as.
// Strings: length first, every memcmp inlined.
//
// REQUIRES: clang
// RUN: rm -rf %t.o2 %t.o3
// RUN: %kairo %s -c -O2 --cache-dir %t.o2
// RUN: %kairo %s -c -O3 --cache-dir %t.o3
// --show-all-symbols: on Mach-O the assembler's ltmp0 shares the first
// function's address and would otherwise be the only label printed there.
// RUN: llvm-objdump --show-all-symbols -d --no-show-raw-insn %t.o2/shapes.o > %t.o2.s
// RUN: llvm-objdump --show-all-symbols -d --no-show-raw-insn %t.o3/shapes.o > %t.o3.s
// RUN: awk '/<[^>]*5level[^>]*>:/,/^$/' %t.o2.s | grep -qE 'ud2|brk'
// RUN: awk '/<[^>]*5level[^>]*>:/,/^$/' %t.o3.s | { ! grep -qE 'ud2|brk'; }
// RUN: test $(awk '/<[^>]*6status[^>]*>:/,/^$/' %t.o2.s | grep -c cmp) -le 4
// RUN: awk '/<[^>]*4word[^>]*>:/,/^$/' %t.o2.s | { ! grep -qE 'call|[[:space:]]bl[[:space:]]'; }
