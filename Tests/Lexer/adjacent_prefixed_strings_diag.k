// P486: a diagnostic inside a later segment of a chain points at that
// segment's bytes: a name in a hole, a hole's format spec, an escape. A
// suffix is read off the head segment only (as for an unprefixed chain): on
// a chain with an f segment it is the f-string suffix error, and a later
// segment's suffix is not consulted.
//
// A lexer error stops before Sema, and a resolution error before typing, so
// each RUN blanks the other groups' lines (tagged at their ends; blanked,
// not deleted, so the line numbers hold).

fn main() -> i32 {
    var x = 7
    var a = "a" f"b{nope}" // resolve
    var c = r"a" "b" f"{x:Q}"
    var e = "a"s f"{x}"
    var d = "a" f"{x}" "c"s
    return 0
}

fn esc() {
    var b = "a" r"\q" f"\q{1}" // escape
}

// --- lit wiring -----------------------------------------------------------
// RUN: sed -e '/\/\/ resolve$/s/.*//' -e '/\/\/ escape$/s/.*//' %s > %t.typing.k
// RUN: { %kairo %t.typing.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TYPING
// TYPING:     .k:14:27: error [SC036E]: invalid format spec 'Q'
// TYPING:     .k:15:13: error [SC074E]: a format string cannot take the literal suffix 's'
// TYPING-NOT: .k:16:
//
// RUN: sed -e '/\/\/ escape$/s/.*//' %s > %t.resolve.k
// RUN: { %kairo %t.resolve.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=RESOLVE
// RESOLVE: .k:13:21: error [R020E]: use of undeclared identifier 'nope'
//
// The raw segment's `\q` is two bytes of text; the f segment's is an error.
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=ESC
// ESC-NOT: :21:20:
// ESC:     adjacent_prefixed_strings_diag.k:21:25: error [S033E]: unknown escape sequence '\q'
