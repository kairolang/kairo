// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// RUN: { %kairo %S/u64_first.k --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// RUN: { %kairo %S/sizes.k %S/words.k --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// RUN: { %kairo %S/words.k %S/sizes.k --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// On LP64 `vector<usize>` and `vector<u64>` are ONE clang
// specialization, `vector<unsigned long>`, but two Kairo instances. Their
// members had one Kairo decl each (one USR), and each fill re-defined them
// with its own argument mapping, so the instance that filled LAST would decide
// the element type of both: `v[i] + n` SC033E 'u64' and 'usize', and
// `w.push_back(x)` SC063E against `const usize&`, depending on input
// order. Each
// instance has its own members over the shared specialization. This
// file names vector<usize> first, u64_first.k the other way round; the
// two-file runs check both input orders.
// CHECK-NOT: error

ffi "c++" import "vector";

fn main() -> i32 {
    var v = cxx::std::vector<usize>();
    var w = cxx::std::vector<u64>();
    const n: usize = 1;
    const x: u64 = 2;
    v.push_back(n);
    w.push_back(x);
    const i: usize = 0;
    const r: usize = v[i] + n;
    const s: u64 = w[i] + x;
    return 0;
}
