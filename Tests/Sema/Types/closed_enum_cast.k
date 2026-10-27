// A plain enum is closed unless `@open`: `as` into it with a CONSTANT
// operand that is no variant's value is SC001E (placeholder), labelled on
// the operand, noting the enum, with a fix-it inserting `@open` before its
// `enum` keyword. In range is fine, a non-constant operand is checked at run
// time (Codegen/enums/closed_enum_cast.k), and an `@open` enum takes any
// value. An enum declared below the cast is checked too (its values are
// written after the cast is typed). `@open` on a forward declaration opens
// the enum. (Misplaced `@open`: open_attr_misuse.k, open_forward_adt.k.)

enum Color derives u8 { Red, Green, Blue }
enum Spread derives u8 { Lo = 1, Hi = 5 }
@open enum Raw derives u8 { X, Y }
const SEVEN: u8 = 7

enum Fwd derives u8
@open enum Fwd2 derives u8

fn casts(v: u8) {
    var a = 2 as Color
    var b = 3 as Color
    var c = 3 as Spread
    var d = 5 as Spread
    var e = 200 as Raw
    var f = SEVEN as Color
    var g = v as Color
    var h = 9 as Later
    var i = 4 as Color?
    var j = 3 as Fwd
    var k = 3 as Fwd2
}

enum Later derives u8 { P, Q }
enum Fwd derives u8 { M, N }
enum Fwd2 derives u8 { M, N }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG:      closed_enum_cast.k:20:13: error [SC001E]: 3 is not a value of 'Color': a closed enum holds only its variants' values
// DIAG-NEXT: fix-it:"{{.*}}closed_enum_cast.k":{10:1-10:1}:"@open "
// DIAG-NEXT: closed_enum_cast.k:10:1: note [I900N]: 'Color' is declared here; it is closed, so a value no variant has is an error
// DIAG:      closed_enum_cast.k:21:13: error [SC001E]: 3 is not a value of 'Spread': a closed enum holds only its variants' values
// DIAG-NEXT: fix-it:"{{.*}}closed_enum_cast.k":{11:1-11:1}:"@open "
// DIAG:      closed_enum_cast.k:24:13: error [SC001E]: 7 is not a value of 'Color': a closed enum holds only its variants' values
// DIAG:      closed_enum_cast.k:26:13: error [SC001E]: 9 is not a value of 'Later': a closed enum holds only its variants' values
// DIAG-NEXT: fix-it:"{{.*}}closed_enum_cast.k":{32:1-32:1}:"@open "
// DIAG:      closed_enum_cast.k:27:13: error [SC001E]: 4 is not a value of 'Color': a closed enum holds only its variants' values
// DIAG:      closed_enum_cast.k:28:13: error [SC001E]: 3 is not a value of 'Fwd': a closed enum holds only its variants' values
