// A pattern head must name something the matched value can be: a variant of
// the scrutinee's enum, the scrutinee's own record type, or a `const` /
// `eval` constant. A bare name is never a binder; anything else is SC123E,
// and a constant given a payload is SC124E. (An UNKNOWN bare head is a name
// resolution error and stops the pipeline earlier; it has its own file,
// pattern_head_unresolved.k.)

enum Color { Red, Green, Blue }
enum Other { A, B }

struct Point { var x: i32; var y: i32; }
struct Size  { var w: i32; var h: i32; }

const MAX: i32 = 10

fn dotted_on_int(x: i32) {
    match x {
        case .North { }
// DIAG: pattern_heads_err.k:[[@LINE-1]]:14: error [SC123E]: '.North' names an enum variant, but the matched value is 'i32', not an enum
        default { }
    }
}

fn misspelled(c: Color) {
    match c {
        case .Gren { }
// DIAG: pattern_heads_err.k:[[@LINE-1]]:14: error [SC123E]: 'Color' has no variant named 'Gren'
        default { }
    }
}

fn other_enum(c: Color) {
    match c {
        case Other::A { }
// DIAG: pattern_heads_err.k:[[@LINE-1]]:14: error [SC123E]: 'Other::A' is a variant of another enum; the matched value is 'Color'
        default { }
    }
}

fn wrong_record(s: Size) {
    match s {
        case Point(var x, var y) { }
// DIAG: pattern_heads_err.k:[[@LINE-1]]:14: error [SC123E]: this pattern matches 'Point', but the matched value is 'Size'
        default { }
    }
}

fn the_enum_itself(c: Color) {
    match c {
        case Color { }
// DIAG: pattern_heads_err.k:[[@LINE-1]]:14: error [SC123E]: 'Color' is an enum; name one of its variants
        default { }
    }
}

fn mutable_local(x: i32) {
    var n: i32 = 3
    match x {
        case n { }
// DIAG: pattern_heads_err.k:[[@LINE-1]]:14: error [SC123E]: 'n' is not a variant, a constant or a type, so it cannot be matched against; to bind the value to a new name, write 'var n'
        default { }
    }
}

fn constant_payload(x: i32) {
    match x {
        case MAX(1) { }
// DIAG: pattern_heads_err.k:[[@LINE-1]]:14: error [SC124E]: 'MAX' is a constant; it takes no payload
        default { }
    }
}

// The positive heads: a constant, a qualified variant, a record. (The parser
// picks Constructor- or UnresolvedConstructorPattern by a shallow lookup;
// either is fine here.)
fn good(k: i32, c: Color, p: Point) {
    match k {
        case MAX { }
// SEMA: {{[A-Za-z]*}}ConstructorPattern @ [[@LINE-1]]:14 [resolved=Const MAX]
        default { }
    }
    match c {
        case Color::Red { }
// SEMA: {{[A-Za-z]*}}ConstructorPattern @ [[@LINE-1]]:14 [resolved=Variant Red]
        case .Green, .Blue { }
    }
    match p {
        case Point(var x, 0) { }
// SEMA: {{[A-Za-z]*}}ConstructorPattern @ [[@LINE-1]]:14 [resolved=Record Point]
// SEMA: BindingPattern @ [[@LINE-2]]:20 [field=x]
// SEMA: LiteralPattern @ [[@LINE-3]]:27 [field=y]
        default { }
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
