class CopyDefault {
    var a: i32;
    var b: i32;
    @copy
    fn CopyDefault(self, const other: Self) = default
}
class CopyBody {
    var a: i32;
    var b: i32;
    @copy
    fn CopyBody(self, const other: Self) { }
}
class MoveDefault {
    var a: i32;
    var b: i32;
    @move
    fn MoveDefault(self, other: Self) = default
}
class MoveBody {
    var a: i32;
    var b: i32;
    @move
    fn MoveBody(self, other: Self) { }
}
class CopyDefaultString {
    var s: string;
    @copy
    fn CopyDefaultString(self, const other: Self) = default
}
class DtorDefault {
    var a: i32;
    @copy
    fn DtorDefault(self, const other: Self) = default
    fn op delete(self) = default
}
class DtorBody {
    var a: i32;
    @copy
    fn DtorBody(self, const other: Self) = default
    fn op delete(self) { }
}
class VirtualDtorDefault {
    var a: i32;
    @copy
    fn VirtualDtorDefault(self, const other: Self) = default
    virtual fn op delete(self) = default
}
class AddsNothing derives DtorBody {
    var b: i32;
    @copy
    fn AddsNothing(self, const other: Self) = default
    fn op delete(self) = default            // expect: clean -- a defaulted destructor does no work of its own
}
enum HoldsCopyDefault { Has { c: CopyDefault }, Empty }
enum HoldsCopyBody { Has { c: CopyBody }, Empty }
enum HoldsMoveDefault { Has { m: MoveDefault }, Empty }

// --- lit wiring -----------------------------------------------------------
// A transfer constructor or destructor declared `= default` is trivial when
// every base and field is, as in C++ (a special member defaulted on its first
// declaration is trivial if each subobject's is). Only one with a body makes
// the class non-trivial by itself. A virtual destructor is never trivial,
// defaulted or not.
//
// An ADT folds its payloads' facts, so one over the defaulted-copy class is
// trivially copyable and one over the hand-written copy is not.
//
// AddsNothing derives a base with a non-trivial, non-virtual destructor, but
// its own destructor is defaulted over an i32: nothing a base-pointer delete
// skips, so the virtual-destructor rule stays silent (its trivial_dtor is
// still the base's 0).
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// DIAG-NOT: {{error|warning}} [
//
// SEMA:      lifecycle CopyDefault: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle CopyBody: category=COPY trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle MoveDefault: category=MOVE trivial_copy=1 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle MoveBody: category=MOVE trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle CopyDefaultString: category=COPY trivial_copy=0 trivial_dtor=0 destructible=1
// SEMA-NEXT: lifecycle DtorDefault: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle DtorBody: category=COPY trivial_copy=0 trivial_dtor=0 destructible=1
// SEMA-NEXT: lifecycle VirtualDtorDefault: category=COPY trivial_copy=0 trivial_dtor=0 destructible=1
// SEMA-NEXT: lifecycle AddsNothing: category=COPY trivial_copy=0 trivial_dtor=0 destructible=1
// SEMA-NEXT: lifecycle HoldsCopyDefault: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle HoldsCopyBody: category=COPY trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle HoldsMoveDefault: category=MOVE trivial_copy=1 trivial_dtor=1 destructible=1
