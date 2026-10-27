// An exhaustive match over an ADT's tag assumes no other tag reaches it
// (spec ENUMLAYOUT §4): sema proved every variant has an arm and no value
// of the enum holds another tag, so the switch's default is
// `__builtin_unreachable()`, and `inst_cost` compiles at -O2 to a bare table
// load -- no compare, no branch to a trap. `--hardening=enum-tags` puts the
// trap back. A plain enum keeps UnmatchedPolicy (trap below -O3): a cast
// makes an undeclared value of one legitimately. A match with a default arm
// dispatches the rest there, as before.

enum Inst {
    Const { value: i32 },
    Binary { op_code: u8, lhs: i32, rhs: i32 },
    Neg { x: i32 },
    Nop,
}

enum Dir { North, East, South, West }

fn inst_cost(i: Inst) -> i32 = match i {
    case .Const  => 1
    case .Binary => 3
    case .Neg    => 2
    case .Nop    => 0
}

fn turn(d: Dir) -> i32 = match d {
    case .North => 1
    case .East  => 2
    case .South => 3
    case .West  => 4
}

fn some(i: Inst) -> i32 = match i {
    case .Neg(var x) => x
    default          => 9
}

fn main() -> i32 {
    var r = 0
    if (inst_cost(Inst::Binary { op_code: 1, lhs: 2, rhs: 3 }) == 3) && (inst_cost(.Nop) == 0) { r += 1 }
    if (turn(.South) == 3) && (turn(.West) == 4) { r += 2 }
    if (some(Inst::Neg { x: 5 }) == 5) && (some(Inst::Const { value: 1 }) == 9) { r += 4 }
    return r                                    // 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}adt_dispatch.k
// IR:       signed int inst_cost(
// IR:       default: __builtin_unreachable();
// IR:       signed int turn(
// IR:       default: __builtin_trap();
// IR:       signed int some(
// IR-NOT:   __builtin_
// IR:       int main()

// RUN: { %kairo %s --print-ir --hardening=enum-tags 2>/dev/null || true; } | %FileCheck %s --check-prefix=HARD
// HARD-LABEL: CODEGEN C++: {{.*}}adt_dispatch.k
// HARD:       signed int inst_cost(
// HARD:       default: __builtin_trap();

// An item --hardening does not know is an error, inside a list too.
// RUN: { %kairo %s --type-check-only --hardening=enum-tags,bogus 2>&1 || true; } | %FileCheck %s --check-prefix=FLAG
// FLAG: error [U003E]: invalid value 'bogus' for flag '--hardening'; accepted: enum-tags

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2 %t.hard
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
// RUN: %kairo %s -c -O2 --cache-dir %t.o2
// RUN: %objdump -d --no-show-raw-insn %t.o2/adt_dispatch.o | awk '/<[^>]*9inst_cost[^>]*>:/,/^$/' | grep -v nop > %t.cost.s
// RUN: grep -q ret %t.cost.s
// RUN: { ! grep -qE 'cmp|test|ud2|brk|unimp|call|[[:space:]]j[a-z]+[[:space:]]|[[:space:]]b\.' %t.cost.s; }
// The hardened build keeps the range check in front of the load.
// RUN: %kairo %s -c -O2 --hardening=enum-tags --cache-dir %t.hard
// RUN: %objdump -d --no-show-raw-insn %t.hard/adt_dispatch.o | awk '/<[^>]*9inst_cost[^>]*>:/,/^$/' > %t.hard.s
// RUN: grep -qE 'ud2|brk|unimp|ebreak' %t.hard.s
