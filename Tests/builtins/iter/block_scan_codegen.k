// A scan over a slice of numbers that ends at the first element a predicate
// decides tests a block of elements at a time when the predicate is
// speculatable: at -O2 and at -O3 each function below holds a vector compare
// and no call (the block's loop is inlined into its caller with the
// predicate). A predicate with an effect keeps the loop over the items, and
// so does a scan over records, whose elements may hold pointers: no vector
// compare.

import std::iter::*

var calls: usize = 0

fn is_mark(p: *const (*const i32)) -> bool = **p == 5000
fn not_mark(p: *const (*const i32)) -> bool = **p != 5000
fn counted_not_mark(p: *const (*const i32)) -> bool {
    calls += 1
    return **p != 5000
}

pub fn count_leading(const s: [const i32;]) -> usize {
    return iter(s.iter()).take_while(not_mark).count()
}

pub fn count_trailing(const s: [const i32;]) -> usize {
    return iter(s.iter()).rev().take_while(not_mark).count()
}

pub fn first_mark(const s: [const i32;]) -> usize {
    return iter(s.iter()).position(is_mark) ?? s.size()
}

pub fn last_mark(const s: [const i32;]) -> usize {
    return iter(s.iter()).rev().position(is_mark) ?? s.size()
}

pub fn has_mark(const s: [const i32;]) -> bool {
    return iter(s.iter()).any(is_mark)
}

pub fn no_mark(const s: [const i32;]) -> bool {
    return iter(s.iter()).all(not_mark)
}

pub fn find_mark(const s: [const i32;]) -> i32 {
    return *(iter(s.iter()).find(is_mark) ?? &s[0])
}

pub fn count_after(const s: [const i32;]) -> usize {
    return iter(s.iter()).skip_while(not_mark).count()
}

pub fn count_observed(const s: [const i32;]) -> usize {
    return iter(s.iter()).take_while(counted_not_mark).count()
}

struct Cell {
    var v: i32
}

fn cell_is_mark(p: *const (*const Cell)) -> bool = (*p)->v == 5000

pub fn first_cell(const s: [const Cell;]) -> usize {
    return iter(s.iter()).position(cell_is_mark) ?? s.size()
}

fn main() -> i32 {
    var v: [i32]
    for var i: i32 = 0; i < 100; i += 1 {
        v.push(i)
    }

    v[70] = 5000
    if count_leading(v) != 70 || count_trailing(v) != 29 || first_mark(v) != 70 || last_mark(v) != 29 {
        return 1
    }

    if !has_mark(v) || no_mark(v) || find_mark(v) != 5000 {
        return 2
    }

    if count_observed(v) != 70 || calls != 71 || count_after(v) != 30 {
        return 3
    }

    var cells: [Cell]
    for var i: i32 = 0; i < 100; i += 1 {
        cells.push(Cell { v: if i == 70 => 5000 else => i })
    }

    if first_cell(cells) != 70 {
        return 4
    }

    return 0
}

// CHECK-LABEL: define {{.*}}13count_leading
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: icmp {{eq|ne}} <{{[0-9]+}} x i32>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}14count_trailing
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: icmp {{eq|ne}} <{{[0-9]+}} x i32>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}10first_mark
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: icmp {{eq|ne}} <{{[0-9]+}} x i32>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}9last_mark
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: icmp {{eq|ne}} <{{[0-9]+}} x i32>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}8has_mark
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: icmp {{eq|ne}} <{{[0-9]+}} x i32>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}7no_mark
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: icmp {{eq|ne}} <{{[0-9]+}} x i32>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}9find_mark
// CHECK: icmp {{eq|ne}} <{{[0-9]+}} x i32>
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}11count_after
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: icmp {{eq|ne}} <{{[0-9]+}} x i32>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}14count_observed
// CHECK-NOT: <{{[0-9]+}} x i32>
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}10first_cell
// CHECK-NOT: <{{[0-9]+}} x i32>
// CHECK: {{^}}}

// --- lit wiring ---
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: rm -f %t.exe
// RUN: %kairo -O2 --target=x86_64-linux-gnu --emit=llvm-ir %s -o %t.ll --cache-dir %t.d
// RUN: %FileCheck %s --input-file=%t.ll
// RUN: rm -rf %t.d
// RUN: %kairo -O3 --target=x86_64-linux-gnu --emit=llvm-ir %s -o %t.O3.ll --cache-dir %t.d
// RUN: %FileCheck %s --input-file=%t.O3.ll
// RUN: rm -rf %t.d
// RUN: %kairo -O2 %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
