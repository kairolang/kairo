ffi "c++" import "<mutex>";
class Unique {
    var n: i32;
    @move
    fn Unique(self, other: Self) = default
}
class Plain {
    var n: i32;
    @copy
    fn Plain(self, const other: Self) = default
}
class NoCopy {
    var n: i32;
    @copy
    fn NoCopy(self, const other: Self) = delete
}
class CopiesUnique {
    var n: i32;
    var u: Unique;
    @copy
    fn CopiesUnique(self, const other: Self) = default   // expect: error SC129E -- 'u' is move-only
}
class MovesMutex {
    var m: cxx::std::mutex;
    @move
    fn MovesMutex(self, other: Self) = default           // expect: error SC129E -- 'm' is not transferable
}
class MovesPlain {
    var s: string;
    var p: Plain;
    @move
    fn MovesPlain(self, other: Self) = default           // expect: clean -- 'p' is copied as part of the move
}
class CopiesBase derives NoCopy {
    @copy
    fn CopiesBase(self, const other: Self) = default     // expect: error SC129E -- base 'NoCopy' is not transferable
}
class <T> CopiesT {
    var v: T;
    @copy
    fn CopiesT(self, const other: Self) = default        // expect: clean -- T decides, per instance
}

// --- lit wiring -----------------------------------------------------------
// A defaulted transfer constructor transfers memberwise: a defaulted `@copy`
// needs every base and field copyable, a defaulted `@move` needs every one
// movable. A COPY-only field under a defaulted `@move` is copied as part of
// the move and stays legal (Classes: Defaulted moves of non-movable members).
// A dependent field is the instance's to decide, so the pattern is clean.
//
// NoCopy deletes its copy, which suppresses the implicit move too, so it is
// NON_TRANSFER. CopiesBase declares COPY over it, which breaks the base
// category rule (SC061E) before the defaulted copy fails on the same base.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// DIAG:      defaulted_transfer.k:21:{{[0-9]+}}: error [SC129E]: 'CopiesUnique' cannot have a defaulted copy constructor: field 'u' of type 'Unique' is move-only
// DIAG-NEXT: defaulted_transfer.k:19:{{[0-9]+}}: note [SC129N]: 'u' declared here
// DIAG-NEXT: defaulted_transfer.k:26:{{[0-9]+}}: error [SC129E]: 'MovesMutex' cannot have a defaulted move constructor: field 'm' of type '{{.*}}mutex' is not transferable
// DIAG-NEXT: defaulted_transfer.k:24:{{[0-9]+}}: note [SC129N]: 'm' declared here
// DIAG-NEXT: defaulted_transfer.k:34:{{[0-9]+}}: error [SC061E]: 'CopiesBase' is copyable (@copy), but its base 'NoCopy' is non-transferable
// DIAG-NEXT: defaulted_transfer.k:12:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: base declared here
// DIAG-NEXT: defaulted_transfer.k:36:{{[0-9]+}}: error [SC129E]: 'CopiesBase' cannot have a defaulted copy constructor: base 'NoCopy' is not transferable
// DIAG-NEXT: defaulted_transfer.k:34:{{[0-9]+}}: note [SC129N]: 'NoCopy' is a base of 'CopiesBase' here
// DIAG-NOT:  {{error|warning}} [
