// A declared conformance is verified at the declaration (extends.mdx,
// Interface Conformance: "The compiler verifies at the `extend`
// declaration that all interface requirements are satisfied. Missing
// methods are a compile error."), whether or not anything uses the type
// through the interface.
//
// XFAIL: *
// Tickets "[Sema] An `extend ... impl` missing interface methods is not
// reported at the `extend`" (private/IMPORTANT/TICKETS.TXT, 2026-10-26;
// status.mdx, Not Diagnosed) and item 4 of "[Sema][Codegen]
// Declared-witness edges left by d51202fb / 21e61694" (a declared
// conformance that does not hold is not diagnosed). Today conformance is
// checked only where a bound meets the type (SC001E "does not conform", as
// in conformance_base_missing.k), so this file is accepted without a word.
// The code is not decided; the check asks for an error at the `extend`.
// When it XPASSes, delete the XFAIL and pin the code and message.

interface Drawable {
    fn draw(const self) -> i32
    fn area(const self) -> i32
}

struct Point {
    pub var x: i32
}

extend Point impl Drawable {
// CHECK: extend_impl_missing.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
    pub fn draw(const self) -> i32 { return self.x }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
