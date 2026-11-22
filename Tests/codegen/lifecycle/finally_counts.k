// `x.finally()` runs a local's destructor where it is written, and the
// scope's end does not run it again (Compiler/Spec/Lowering.md#union-storage-locals).
// Every control-flow shape below destroys each object exactly once: the
// program prints one `~Res N` per object and checks the count itself.
// A local no `finally()` ends keeps plain `T x` storage; one every exit
// reaches ended is a union with no cleanup; one some exits reach alive is a
// union beside a `live` flag its cleanup hook tests.
import std::io::println

var dtors: i32 = 0

class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) {
        dtors += 1
        println(f"~Res {self.id}")
    }
}

fn none() {
    var r = Res(1)
    println("none")
}

fn uncond() {
    var r = Res(2)
    r.finally()
    println("after uncond")
}

fn branch(c: bool) {
    var r = Res(3)
    if c {
        r.finally()
        println("ended in branch")
    }
    println("end of branch")
}

fn both_arms(c: bool) {
    var r = Res(4)
    if c {
        r.finally()
    } else {
        r.op finally()
    }
    println("both arms")
}

fn early(c: bool) -> i32 {
    var r = Res(5)
    if c {
        r.finally()
        return 1
    }
    println("no early return")
    return 0
}

fn in_loop() {
    var r = Res(6)
    for var i: i32 = 0; i < 3; ++i {
        if i == 1 {
            r.finally()
            break
        }
        println(f"iteration {i}")
    }
    println("after loop")
}

fn per_iteration() {
    for var i: i32 = 0; i < 2; ++i {
        var r = Res(70 + i)
        r.finally()
    }
    println("after per_iteration")
}

// A move out of a local ends it too: the moved-from object is not
// destroyed, and `finally()` on it afterwards is SC052E.
fn moved_from() {
    var r = Res(8)
    var q = r
    println("moved_from")
}

fn returned() -> Res {
    var r = Res(9)
    if dtors < 0 {
        r.finally()
        return Res(90)
    }
    return r
}

// A `finally()` no path reaches still gives the local its storage: the
// call is written, and the return destroys the object.
fn unreachable() -> i32 {
    var r = Res(10)
    return 0
    r.finally()
}

fn main() -> i32 {
    unreachable()
    none()
    uncond()
    branch(true)
    branch(false)
    both_arms(true)
    both_arms(false)
    early(true)
    early(false)
    in_loop()
    per_iteration()
    moved_from()
    {
        var k = returned()
        println("got returned")
    }
    println(f"dtors {dtors}")
    if dtors != 14 {
        return 1
    }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// The one diagnostic is the unreachable `finally()` in `unreachable()`.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: warning [SC003W]: unreachable code

// The three storage forms, in the generated C++.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: void none() noexcept {
// CXX: ::{{.*}}::Res r = ::{{.*}}::Res(1);
// CXX-LABEL: void uncond() noexcept {
// CXX: ::__kairo_ul< ::{{.*}}::Res> __k_s_r {
// CXX-NOT: cleanup
// CXX: __k_s_r.__end();
// CXX-LABEL: void branch(bool c) noexcept {
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_r {
// CXX: __attribute((cleanup(__kairo_ul_run)))::__kairo_ulh __k_h_r {
// CXX: __k_s_r.__end();
// CXX-LABEL: void both_arms(bool c) noexcept {
// CXX: ::__kairo_ul< ::{{.*}}::Res> __k_s_r {
// CXX-NOT: cleanup
// CXX: __k_s_r.__end();
// CXX-NOT: cleanup
// CXX: __k_s_r.__end();
// CXX-NOT: cleanup
// CXX: println({{.*}}.b, 9, 9)
// CXX-LABEL: ::{{.*}}::Res returned() noexcept {
// CXX: return static_cast< ::{{.*}}::Res &&>(__k_s_r.v);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~Res 10
// OUT-NEXT: none
// OUT-NEXT: ~Res 1
// OUT-NEXT: ~Res 2
// OUT-NEXT: after uncond
// OUT-NEXT: ~Res 3
// OUT-NEXT: ended in branch
// OUT-NEXT: end of branch
// OUT-NEXT: end of branch
// OUT-NEXT: ~Res 3
// OUT-NEXT: ~Res 4
// OUT-NEXT: both arms
// OUT-NEXT: ~Res 4
// OUT-NEXT: both arms
// OUT-NEXT: ~Res 5
// OUT-NEXT: no early return
// OUT-NEXT: ~Res 5
// OUT-NEXT: iteration 0
// OUT-NEXT: ~Res 6
// OUT-NEXT: after loop
// OUT-NEXT: ~Res 70
// OUT-NEXT: ~Res 71
// OUT-NEXT: after per_iteration
// OUT-NEXT: moved_from
// OUT-NEXT: ~Res 8
// OUT-NEXT: got returned
// OUT-NEXT: ~Res 9
// OUT-NEXT: dtors 14
// OUT-EMPTY:
