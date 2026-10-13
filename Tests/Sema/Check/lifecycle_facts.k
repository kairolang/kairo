ffi "c++" import "<mutex>";
class Unique {
    var n: i32;
    @move fn Unique(self, other: Self) = default;
}
class ScopeLock {
    fn ScopeLock(self) = default
    @copy
    fn ScopeLock(self, const other: Self) = delete
    @move
    fn ScopeLock(self, other: Self) = delete
    fn op delete(self) { }
}
enum Mode { Read, Write }
enum Num { One { n: i32 }, Two { p: *i32 } }
enum Text { Some { s: string }, None }
enum Owned { Has { u: Unique }, Empty }
enum Locked { Held { m: cxx::std::mutex }, Free }
enum Guarded { Held { g: ScopeLock }, Free }
enum <T> Opt { Some { v: T }, None }
enum <T> Mixed { A { s: string }, B { v: T } }
class <T> Box { var v: T; }
class <T> Ptr { var p: *T; }

// --- lit wiring -----------------------------------------------------------
// ClassLifecycle's facts, one --print-sema row per class, struct and enum,
// at the foot of the scope-tables section. The builtin TUs are dumped first
// and print none.
//
//   Mode     a plain enum is an integer: trivially everything.
//   Num      an ADT over i32 and a pointer: still trivially everything.
//   Text     a `string` payload: not trivially copyable or destroyed.
//   Owned    a move-only payload makes the ADT move-only.
//   Locked   clang's std::mutex is neither copyable nor movable; its
//            triviality bits are the C++ library's, so they are not pinned.
//   Guarded  a NON_TRANSFER Kairo class payload (both transfers deleted).
//   Opt      a `T` payload: every fact waits for an instance.
//   Mixed    one `string` payload decides triviality whatever T is; the rest
//            waits for an instance.
//   Box      a record's dependent field is unknown the same way.
//   Ptr      `*T` is an address whatever T is.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// DIAG-NOT: {{error|warning}} [
//
// SEMA-NOT:  lifecycle {{[A-Za-z]+}}: category=
// SEMA:      ===== SEMA fid {{[0-9]+}}: {{.*}}lifecycle_facts.k =====
// SEMA:      -- scope symbol tables (what each scope declares) --
// SEMA:        lifecycle Unique: category=MOVE trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT:   lifecycle ScopeLock: category=NON_TRANSFER trivial_copy=0 trivial_dtor=0 destructible=1
// SEMA-NEXT:   lifecycle Mode: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// SEMA-NEXT:   lifecycle Num: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// SEMA-NEXT:   lifecycle Text: category=COPY trivial_copy=0 trivial_dtor=0 destructible=1
// SEMA-NEXT:   lifecycle Owned: category=MOVE trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT:   lifecycle Locked: category=NON_TRANSFER trivial_copy={{[01]}} trivial_dtor={{[01]}} destructible=1
// SEMA-NEXT:   lifecycle Guarded: category=NON_TRANSFER trivial_copy=0 trivial_dtor=0 destructible=1
// SEMA-NEXT:   lifecycle Opt: category=? trivial_copy=? trivial_dtor=? destructible=?
// SEMA-NEXT:   lifecycle Mixed: category=? trivial_copy=0 trivial_dtor=0 destructible=?
// SEMA-NEXT:   lifecycle Box: category=? trivial_copy=? trivial_dtor=? destructible=?
// SEMA-NEXT:   lifecycle Ptr: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// SEMA-NEXT: -- multi-decl names (overload sets / redecl chains) --
