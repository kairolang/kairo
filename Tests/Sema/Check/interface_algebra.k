// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } | %FileCheck %s --check-prefix=SEMA
//
// InterfaceComposition normalizes each interface into a plain requirement
// list. --print-sema prints, per composed interface, its requirement count
// and the derived body as Kairo source: the text an LSP shows after the
// derives clause (own members are counted, not repeated).
//
// DIAG-NOT: error
//
// SEMA-LABEL: ===== SEMA fid {{[0-9]+}}: {{.*}}interface_algebra.k =====
// SEMA: -- interface composition --
// Union: both, once each.
// SEMA: Z  2 requirement(s)
// SEMA-NEXT: {
// SEMA-NEXT: fn add(self)
// SEMA-NEXT: fn sub(self)
// SEMA-NEXT: }
// Difference, then an own member: (X + Y) - R keeps sub; extra is own.
// SEMA-NEXT: U  2 requirement(s)
// SEMA-NEXT: {
// SEMA-NEXT: fn sub(self)
// SEMA-NEXT: }
// Intersection: only add is in both.
// SEMA-NEXT: I  1 requirement(s)
// SEMA-NEXT: {
// SEMA-NEXT: fn add(self)
// SEMA-NEXT: }
// Trap A: generic bounds are part of identity, so A - B keeps A's process.
// SEMA-NEXT: AB  1 requirement(s)
// SEMA-NEXT: {
// SEMA-NEXT: fn <T> process(self, v: T)
// SEMA-NEXT: }
// A - A is empty; the own member keeps it an interface.
// SEMA-NEXT: AA  1 requirement(s)
// `-` matches on identity alone, whatever the return types.
// SEMA-NEXT: DD  1 requirement(s)
// Trap C: two `type Item`s are one, with the bounds of both.
// SEMA-NEXT: CU  2 requirement(s)
// SEMA-NEXT: {
// SEMA-NEXT: fn get(self) -> Self::Item
// SEMA-NEXT: type Item impl Disp, Num
// SEMA-NEXT: }
// A diamond: X reached through Z and directly is one requirement.
// SEMA-NEXT: Dia  2 requirement(s)

interface X { fn add(self) }
interface Y { fn sub(self) }
interface Z derives X + Y { }
interface R { fn add(self) fn mul(self) }
interface U derives Z - R { fn extra(self) }
interface I derives R & Z { }
interface A { fn <T> process(self, v: T) }
interface S { fn put(self) }
interface B { fn <T impl S> process(self, v: T) }
interface AB derives A - B { }
interface AA derives A - A { fn keep(self) }
interface D1 { fn goo(self) -> i64 }
interface D2 { fn goo(self) -> i32 }
interface DD derives D1 - D2 { fn k(self) }
interface Disp { fn show(const self) -> i32 }
interface Num { fn num(const self) -> i32 }
interface C1 { type Item impl Disp  fn get(self) -> Self::Item }
interface C2 { type Item impl Num }
interface CU derives C1 + C2 { }
interface Dia derives Z + X { }
