// `@set_scoped_allocator(A)` stands for classes of the builtin library's
// allocation module. In a build without it the attribute is an error where
// it is written, never accepted and ignored: on a class or struct it is
// SC366E, and on a function the guard's class is an undeclared name.

class A { }

@set_scoped_allocator(A)
class Log {
    var n: i32 = 0
    fn bump(self) { self.n += 1 }
}

fn use_log() -> i32 {
    var l = Log()
    l.bump()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --no-prelude 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: scoped_allocator_no_prelude.k:8:1: error [SC366E]: '@set_scoped_allocator' on a class or struct needs the builtin library's allocation module ('builtin::base::alloc'), which this build does not have
//
// RUN: sed -e 's/^class Log {/fn scoped() -> i32 {/' -e '/var n: i32 = 0/d' -e 's/    fn bump(self) { self.n += 1 }/    return 0/' -e '/var l = Log()/d' -e '/l.bump()/d' %s > %t.k
// RUN: { %kairo %t.k --type-check-only --no-prelude 2>&1 || true; } | %FileCheck %s --check-prefix=FN --implicit-check-not="error ["
// FN: error [R020E]: use of undeclared identifier 'AllocatorScope'
