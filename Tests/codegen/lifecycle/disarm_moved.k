// The plumbing that lets a provider skip a moved-from local's destructor
// (sema/check/LocalDisposition.k, disarm_local_at), driven by its TEST
// provider: --test-disarm-moved-locals is a compiler test hook, not a
// language feature (sema/check/TestDisarm.k). Under it a local moved once,
// by a real transfer, in straight-line code at the top level of its block,
// is not destroyed again; the object it moved into is destroyed once.
// Without the switch every move is as it is today: the moved-from object
// (id 0 here) is destroyed when its scope ends.
import std::io::println

class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) { println(f"~Res {self.id}") }
}

fn take(r: Res) { println(f"took {r.id}") }

fn borrow(@move r: Res) { println(f"borrowed {r.id}") }

// Disarmed under the switch: into a variable, into a by-value parameter.
fn into_var() {
    var a = Res(1)
    var b = a
    println("into_var")
}

fn into_param() {
    var a = Res(2)
    take(a)
    println("into_param")
}

// Disarmed, flagged: the function can unwind, so an exit the checker does
// not see may come before the move.
@unwind fn flagged() {
    var a = Res(3)
    var b = a
    println("flagged")
}

// Never disarmed: a `@move` parameter is a reference to the caller's
// object, not a transfer of it; a move under a branch; a local assigned
// again after the move.
fn not_real() {
    var a = Res(4)
    borrow(a)
    println("not_real")
}

fn in_branch(c: bool) {
    var a = Res(5)
    if c {
        var b = a
    }
    println("in_branch")
}

fn reassigned() {
    var a = Res(6)
    var b = a
    a = Res(60)
    println("reassigned")
}

fn main() -> i32 {
    into_var()
    into_param()
    flagged()
    not_real()
    in_branch(true)
    reassigned()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --test-disarm-moved-locals 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The disarmed moves: elided storage and a plain cast, or flagged storage
// whose cast clears `live`; the rest keep plain locals.
// RUN: { %kairo %s --print-ir --test-disarm-moved-locals 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: void into_var() noexcept {
// CXX: ::__kairo_ul< ::{{.*}}::Res> __k_s_a {
// CXX-NOT: cleanup
// CXX: b = static_cast< ::{{.*}}::Res &&>(__k_s_a.v);
// CXX-LABEL: void flagged() {
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_a {
// CXX: __attribute((cleanup(__kairo_ul_run)))
// CXX: b =(__k_s_a.live = false, static_cast< ::{{.*}}::Res &&>(__k_s_a.s.v));
// CXX-LABEL: void not_real() noexcept {
// CXX: ::{{.*}}::Res a = ::{{.*}}::Res(4);
// CXX-LABEL: void in_branch(bool c) noexcept {
// CXX: ::{{.*}}::Res a = ::{{.*}}::Res(5);
// CXX-LABEL: void reassigned() noexcept {
// CXX: ::{{.*}}::Res a = ::{{.*}}::Res(6);

// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -o %t.exe --cache-dir %t.d --test-disarm-moved-locals
// RUN: %t.exe | %FileCheck %s --check-prefix=ON --match-full-lines
// ON:      into_var
// ON-NEXT: ~Res 1
// ON-NEXT: took 2
// ON-NEXT: ~Res 2
// ON-NEXT: into_param
// ON-NEXT: flagged
// ON-NEXT: ~Res 3
// ON-NEXT: borrowed 4
// ON-NEXT: not_real
// ON-NEXT: ~Res 4
// ON-NEXT: ~Res 5
// ON-NEXT: in_branch
// ON-NEXT: ~Res 0
// ON-NEXT: ~Res 0
// ON-NEXT: ~Res 0
// ON-NEXT: reassigned
// ON-NEXT: ~Res 6
// ON-NEXT: ~Res 60
// ON-EMPTY:

// RUN: %kairo %s -o %t.off --cache-dir %t.e
// RUN: %t.off | %FileCheck %s --check-prefix=OFF --match-full-lines
// OFF:      into_var
// OFF-NEXT: ~Res 1
// OFF-NEXT: ~Res 0
// OFF-NEXT: took 2
// OFF-NEXT: ~Res 2
// OFF-NEXT: into_param
// OFF-NEXT: ~Res 0
// OFF-NEXT: flagged
// OFF-NEXT: ~Res 3
// OFF-NEXT: ~Res 0
// OFF-NEXT: borrowed 4
// OFF-NEXT: not_real
// OFF-NEXT: ~Res 4
// OFF-NEXT: ~Res 5
// OFF-NEXT: in_branch
// OFF-NEXT: ~Res 0
// OFF-NEXT: ~Res 0
// OFF-NEXT: ~Res 0
// OFF-NEXT: reassigned
// OFF-NEXT: ~Res 6
// OFF-NEXT: ~Res 60
// OFF-EMPTY:
