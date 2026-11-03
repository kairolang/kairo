// The hot paths of `{K: V}` / `{T}` at -O2 (Lib/builtin/containers/
// hash_map.k, hash_set.k, hash_index.k): instruction counts pinned so a
// change that adds work to a lookup, an insert or a walk shows up here.
// Each k_* is one operation on a u64-keyed map (or a u32 set, or a string
// map) kept out of line so its code can be read off the binary.
//
//   lookup (contains / get / `[]` hit): the hash (one `mul`, two `xor`),
//     the tag (one `imul`, one `shr`), the home slot, then per probe one
//     slot load, an empty test, a tag compare and -- on a tag hit -- one
//     key compare. No call, no stack frame.
//   insert of a new key, `[]` of a missing one: the same probe, then a
//     call to the out-of-line add (construction, growth); never inlined.
//   iteration (`for (k, v) in m`, `for *e in m.entries()`): the
//     generator's coroutine frame is elided: a plain loop over the dense
//     entries, vectorized.
import builtin::base::alloc::*

@no_inline fn k_contains(const m: {u64: u64}, k: u64) -> bool { return m.contains(k) }
@no_inline fn k_index(m: {u64: u64}, k: u64) -> u64 { return m[k] }
@no_inline fn k_insert(m: {u64: u64}, k: u64) -> bool { return m.insert(k, k) }
@no_inline fn k_iter(m: {u64: u64}) -> u64 {
    var t: u64 = 0
    for (k, v) in m { t += v }
    return t
}
@no_inline fn k_entries(m: {u64: u64}) -> u64 {
    var t: u64 = 0
    for *e in m.entries() { t += e->value }
    return t
}
@no_inline fn k_set_contains(const s: {u32}, k: u32) -> bool { return s.contains(k) }
@no_inline fn k_str_contains(const m: {string: i32}, const k: string) -> bool { return m.contains(k) }

fn main() -> i32 {
    var m: {u64: u64}
    var i: u64 = 0
    while i < 100 { m[i] = i; i += 1 }
    var s: {u32} = {1u32, 2u32}
    var sm: {string: i32} = {"a": 1}
    var r: u64 = 0
    if k_contains(m, 5) { r += 1 }
    r += k_index(m, 7)
    if k_insert(m, 1000) { r += 1 }
    r += k_iter(m) + k_entries(m)
    if k_set_contains(s, 2u32) { r += 1 }
    if k_str_contains(sm, "a") { r += 1 }
    return (r % 200) as i32                         // 11911 % 200
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, llvm-objdump, sysroot-x86_64-linux-musl
// RUN: rm -rf %t.d
// RUN: %kairo %s --target=x86_64-linux-musl -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 111
// RUN: %objdump -d --no-show-raw-insn %t.exe > %t.asm
// RUN: %FileCheck %s < %t.asm
//
// Instruction counts (the body's lines, padding included): a regression
// past these fails; a gain should lower them.
// RUN: test $(awk '/10k_containsE.*>:/{f=1;next} f&&/^$/{exit} f' %t.asm | wc -l) -le 41
// RUN: test $(awk '/7k_indexE.*>:/{f=1;next} f&&/^$/{exit} f' %t.asm | wc -l) -le 58
// RUN: test $(awk '/8k_insertE.*>:/{f=1;next} f&&/^$/{exit} f' %t.asm | wc -l) -le 50
// RUN: test $(awk '/14k_set_containsE.*>:/{f=1;next} f&&/^$/{exit} f' %t.asm | wc -l) -le 41
//
// A lookup calls nothing and keeps no frame; the probe is one 64-bit
// multiply for the hash and one for the tag.
// CHECK-LABEL: 10k_containsE{{.*}}>:
// CHECK-NOT: {{call|push}}
// CHECK: mulq
// CHECK-NOT: {{call|push}}
// CHECK: imulq
// CHECK-NOT: {{call|push}}
// CHECK: retq
// CHECK-LABEL: 7k_indexE{{.*}}>:
// CHECK: callq {{.*}}add_default
// CHECK-LABEL: 8k_insertE{{.*}}>:
// CHECK: callq {{.*}}3add
// A walk is a loop over the entries: no resume, no frame allocation.
// CHECK-LABEL: 6k_iterE{{.*}}>:
// CHECK-NOT: call
// CHECK: retq
// CHECK-LABEL: 9k_entriesE{{.*}}>:
// CHECK-NOT: call
// CHECK: retq
// CHECK-LABEL: 14k_set_containsE{{.*}}>:
// CHECK-NOT: {{call|push}}
// CHECK: retq
// A string lookup calls the byte hash and, on a tag hit, compares bytes.
// CHECK-LABEL: 14k_str_containsE{{.*}}>:
// CHECK-NOT: default
// CHECK: callq {{.*}}hash_bytes_seeded
