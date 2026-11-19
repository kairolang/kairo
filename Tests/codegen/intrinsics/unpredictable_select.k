// `__builtin_unpredictable(c)` and `@unpredictable if c` are clang's
// `__builtin_unpredictable` at the branch: as an `if`'s whole condition the
// builtin is spelled bare, the one form clang keeps the hint on, so the
// branch-free binary search step stays a conditional move at -O2. The same
// loop with no hint keeps a data-dependent conditional jump. Elsewhere the
// call is `static_cast<bool>(__builtin_unpredictable(c))`.

@no_inline
pub fn plain(b: unsafe *const u64, n: usize, v: u64) -> usize {
    var lo: usize  = 0
    var len: usize = n
    while len > 1 {
        var h = len / 2
        unsafe {
            if b[lo + h - 1] < v { lo += h }
        }
        len -= h
    }
    return lo
}

@no_inline
pub fn hinted(b: unsafe *const u64, n: usize, v: u64) -> usize {
    var lo: usize  = 0
    var len: usize = n
    while len > 1 {
        var h = len / 2
        unsafe {
            if __builtin_unpredictable(b[lo + h - 1] < v) { lo += h }
        }
        len -= h
    }
    return lo
}

@no_inline
pub fn marked(b: unsafe *const u64, n: usize, v: u64) -> usize {
    var lo: usize  = 0
    var len: usize = n
    while len > 1 {
        var h = len / 2
        unsafe {
            @unpredictable if b[lo + h - 1] < v { lo += h }
        }
        len -= h
    }
    return lo
}

fn main() -> i32 {
    var xs: [u64] = [1, 3, 5, 7, 9, 11, 13, 15]
    var unsafe *p = unsafe (xs.data() as unsafe *const u64)
    var a = plain(p, xs.size(), 9)
    var b = hinted(p, xs.size(), 9)
    var c = marked(p, xs.size(), 9)
    return if (a == 4 && b == 4 && c == 4) => (0) else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: hinted(const typename::__kairo_ma<unsigned long>::t * b, decltype(sizeof(0)) n, unsigned long v) noexcept {
// CXX:       if(__builtin_unpredictable((b[
// CXX-LABEL: marked(const typename::__kairo_ma<unsigned long>::t * b, decltype(sizeof(0)) n, unsigned long v) noexcept {
// CXX:       if(__builtin_unpredictable((b[

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe

// REQUIRES: host-x86_64
// RUN: rm -rf %t.dir && mkdir -p %t.dir
// RUN: cd %t.dir && %kairo %s -O2 -S -o %t.dir/out.s
// RUN: %FileCheck %s --check-prefix=ASM --input-file=%t.dir/out.s
// ASM-LABEL: 5plainEPKmmm:
// ASM-NOT:   cmov
// ASM:       cmpq %rdx, -8(%rdi,%r{{[a-z0-9]+}},8)
// ASM-NEXT:  jb
// ASM-LABEL: 6hintedEPKmmm:
// ASM:       cmpq %rdx, -8(%rdi,%r{{[a-z0-9]+}},8)
// ASM-NEXT:  cmovbq
// ASM-LABEL: 6markedEPKmmm:
// ASM:       cmpq %rdx, -8(%rdi,%r{{[a-z0-9]+}},8)
// ASM-NEXT:  cmovbq
