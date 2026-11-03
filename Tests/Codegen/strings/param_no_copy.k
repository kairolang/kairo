// P331: a call to a function whose string parameter is never mutated binds
// the caller's string (`const string&`), so passing an OWNED string costs
// no allocation. Counted by a global allocator that forwards to System. A
// parameter the body mutates still gets its copy (one block per call), and
// so does a call through a `fn` value: the adapter takes the type's
// by-value parameter, which costs what the by-value call did before.

import builtin::base::alloc::*

static allocs: i64 = 0
static live: i64 = 0

class Counting {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { allocs += 1; live += 1; return System::alloc(size, align) }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { allocs += 1; live += 1; return System::alloc_zeroed(size, align) }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { live -= 1; System::free(ptr, size, align) }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return System::resize(ptr, o, n, align) }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return System::realloc(ptr, o, n, align) }
}

@set_global_allocator(Counting)

@no_inline fn reads(s: string) -> usize { return s.length() }
@no_inline fn forwards(s: string) -> usize { return reads(s) + 1 }
@no_inline fn mutates(s: string) -> usize { s.push_back(33); return s.length() }

fn main() -> i32 {
    var s = string()
    for var i: usize = 0; i < 1000; ++i { s.push_back(120) }
    var base = allocs
    var total: usize = 0
    for var i: usize = 0; i < 100; ++i { total += reads(s) + forwards(s) }
    if total != 200100 { return 1 }
    if allocs != base { return 2 }          // no copy on either call

    base = allocs
    for var i: usize = 0; i < 10; ++i { total += mutates(s) }
    if allocs - base != 10 { return 3 }     // one copy per call

    base = allocs
    var f = reads
    for var i: usize = 0; i < 10; ++i { total += f(s) }
    // Two blocks per call, as before P331: __kairo_fn's by-value argument,
    // then its forward into the adapter's (a move of a COPY string copies
    // until P299's successor lands).
    if allocs - base != 20 { return 4 }
    if s.length() != 1000 { return 5 }
    return 42
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:23:21: warning [SC001W]: parameter 's' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{23:21-23:21}:"const "
// DIAG: {{.*}}:24:24: warning [SC001W]: parameter 's' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{24:24-24:24}:"const "
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 42
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
