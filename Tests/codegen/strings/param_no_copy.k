// A call to a function whose parameter of a COPY, non-trivially-copyable
// record is never mutated binds the caller's value (`const T&`), so passing
// one costs no copy. Counted by the record's copy constructor and by a
// global allocator that forwards to System. A parameter the body mutates
// still gets its copy (one per call), and so does a call through a `fn`
// value: the adapter takes the type's by-value parameter, two copies per
// call. A string is MOVE, so a by-value string parameter takes the caller's
// string; a read-only one is written `const`, which borrows and allocates
// nothing.

import builtin::base::alloc::*

static allocs: i64 = 0
static live: i64 = 0
static copies: i64 = 0

class Counting {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { allocs += 1; live += 1; return System::alloc(size, align) }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { allocs += 1; live += 1; return System::alloc_zeroed(size, align) }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { live -= 1; System::free(ptr, size, align) }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return System::resize(ptr, o, n, align) }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return System::realloc(ptr, o, n, align) }
}

@set_global_allocator(Counting)

class Text {
    pub var s: string
    pub fn Text(self) { self.s = string() }
    @copy pub fn Text(self, const other: Self) { self.s = other.s.copy(); copies += 1 }
    pub fn size(const self) -> usize { return self.s.size() }
    pub fn push(self, c: char) { self.s.push(c) }
}

@no_inline fn reads(t: Text) -> usize { return t.size() }
@no_inline fn forwards(t: Text) -> usize { return reads(t) + 1 }
@no_inline fn mutates(t: Text) -> usize { t.push('!'); return t.size() }
@no_inline fn borrows(const s: string) -> usize { return s.size() }

fn main() -> i32 {
    var t = Text()
    for var i: usize = 0; i < 1000; ++i { t.push('x') }
    var base = copies
    var abase = allocs
    var total: usize = 0
    for var i: usize = 0; i < 100; ++i { total += reads(t) + forwards(t) }
    if total != 200100 { return 1 }
    if (copies != base) || (allocs != abase) { return 2 }   // no copy on either call

    base = copies
    for var i: usize = 0; i < 10; ++i { total += mutates(t) }
    if copies - base != 10 { return 3 }     // one copy per call

    base = copies
    var f = reads
    for var i: usize = 0; i < 10; ++i { total += f(t) }
    // Two copies per call: __kairo_fn's by-value argument, then its forward
    // into the adapter's (Text has no move constructor, so a move copies).
    if copies - base != 20 { return 4 }

    var s = string()
    for var i: usize = 0; i < 1000; ++i { s.push('x') }
    abase = allocs
    for var i: usize = 0; i < 100; ++i { total += borrows(s) }
    if allocs != abase { return 5 }         // a const string borrows
    if (t.size() != 1000) || (s.size() != 1000) { return 6 }
    return 42
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:35:21: warning [SC224W]: parameter 't' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{35:21-35:21}:"const "
// DIAG: {{.*}}:36:24: warning [SC224W]: parameter 't' is never mutated; declare it 'const'
// DIAG-NEXT: fix-it:"{{.*}}":{36:24-36:24}:"const "
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 42
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
