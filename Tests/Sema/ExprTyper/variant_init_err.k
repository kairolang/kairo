// A variant is built from its own payload: every field once, by name, in
// any order, in braces exactly when it has one. A name the payload does not
// have is SC040E, as for a struct; the rest of the payload's shape is
// SC131E. A dotted variant takes its enum from the expected type, and it is
// SC123E, as for a dotted pattern, when nothing gives it one, when that type
// is not an enum, or when the enum has no variant of the name.

enum Shape { Circle { r: i32 }, Rect { w: i32, h: i32 }, Empty }
enum Dir { North, South }

fn heads(p: *i32) {
    var a = Shape::Rect { w: 1 };
// DIAG:      variant_init_err.k:[[@LINE-1]]:13: error [SC131E]: 'Shape::Rect' is missing field 'h'
// DIAG-NEXT: variant_init_err.k:8:48: note [SC131N]: declared here
    var b = Shape::Rect { w: 1, w: 2, h: 3 };
// DIAG:      variant_init_err.k:[[@LINE-1]]:33: error [SC131E]: field 'w' of 'Shape::Rect' is given twice
// DIAG-NEXT: variant_init_err.k:[[@LINE-2]]:27: note [SC131N]: first given here
    var c = Shape::Rect { w: 1, h: 2, d: 3 };
// DIAG:      variant_init_err.k:[[@LINE-1]]:39: error [SC040E]: 'Shape::Rect' has no field named 'd'
    var d = Shape::Empty { };
// DIAG:      variant_init_err.k:[[@LINE-1]]:13: error [SC131E]: 'Shape::Empty' carries no payload; write it without braces
// DIAG-NEXT: variant_init_err.k:8:58: note [SC131N]: declared here without a payload
    var e = Shape::Circle;
// DIAG:      variant_init_err.k:[[@LINE-1]]:13: error [SC131E]: 'Shape::Circle' carries a payload; give its fields in braces after the name
// DIAG-NEXT: variant_init_err.k:8:14: note [SC131N]: declared here with its payload
    var f = Shape::Circle { r: p };
// DIAG:      variant_init_err.k:[[@LINE-1]]:32: error [SC028E]: cannot convert '*i32' to 'i32'
    var g = Dir::North { };
// DIAG:      variant_init_err.k:[[@LINE-1]]:13: error [SC131E]: 'Dir::North' carries no payload; write it without braces
// DIAG-NEXT: variant_init_err.k:9:12: note [SC131N]: declared here without a payload
}

fn dotted() {
    var a: Shape = .Circle;
// DIAG:      variant_init_err.k:[[@LINE-1]]:20: error [SC131E]: 'Shape::Circle' carries a payload; give its fields in braces after the name
// DIAG-NEXT: variant_init_err.k:8:14: note [SC131N]: declared here with its payload
    var b: Shape = .Empty { };
// DIAG:      variant_init_err.k:[[@LINE-1]]:20: error [SC131E]: 'Shape::Empty' carries no payload; write it without braces
// DIAG-NEXT: variant_init_err.k:8:58: note [SC131N]: declared here without a payload
    var c: Shape = .Square;
// DIAG:      variant_init_err.k:[[@LINE-1]]:20: error [SC123E]: 'Shape' has no variant named 'Square'
    var d: i32 = .North;
// DIAG:      variant_init_err.k:[[@LINE-1]]:18: error [SC123E]: '.North' names an enum variant, but the expected type is 'i32', not an enum
    var e = .North;
// DIAG:      variant_init_err.k:[[@LINE-1]]:13: error [SC123E]: '.North' names an enum variant, but nothing here gives it an enum type; write the enum's name before it
}

// As an argument, `.V` takes the parameter's enum. With none to take -- an
// enum without the variant, or a generic parameter -- no function is viable.
fn take_dir(d: Dir) { }
fn <T> take_any(x: T) { }

fn arguments() {
    take_dir(.Square);
// DIAG:      variant_init_err.k:[[@LINE-1]]:5: error [SC063E]: no matching overload for call to 'take_dir'
// DIAG-NEXT: variant_init_err.k:[[@LINE-6]]:1: note [I900N]: candidate not viable: cannot convert argument of type '.Square' to parameter 'd' of type 'Dir'
    take_any(.North);
// DIAG:      variant_init_err.k:[[@LINE-1]]:5: error [SC063E]: no matching overload for call to 'take_any'
// DIAG-NEXT: variant_init_err.k:[[@LINE-8]]:1: note [I900N]: candidate not viable: cannot convert argument of type '.North' to parameter 'x' of type 'T'
}

// A bare generic parameter could be any enum, or none: the instance decides,
// and nothing is reported here.
fn <T> pick() -> T {
    return .North;
}

// Overloads are told apart only by which enum has the variant. When both
// parameters' enums have it, `.V` takes either one exactly, neither is
// better, and the call is ambiguous -- not resolved by declaration order.
enum Slot { Full { n: i32 }, Empty }
fn place(s: Shape) { }
fn place(s: Slot) { }

fn tied() {
    place(.Empty);
// DIAG:      variant_init_err.k:[[@LINE-1]]:5: error [SC064E]: call to 'place' is ambiguous: more than one candidate matches at the same rank
// DIAG-NEXT: variant_init_err.k:[[@LINE-6]]:1: note [I900N]: candidate declared here
// DIAG-NEXT: variant_init_err.k:[[@LINE-6]]:1: note [I900N]: candidate declared here
// DIAG-NEXT: variant_init_err.k:[[@LINE-4]]:5: note [I900N]: '.Empty' is a variant of more than one candidate's enum; write the enum name: Shape::Empty or Slot::Empty
}

// Both take `.Empty` as a Shape: naming the enum decides nothing, the tie is
// in the other argument, and the hint is the cast one.
fn put(s: Shape, x: i64) { }
fn put(s: Shape, x: f64) { }

fn tied_elsewhere() {
    put(.Empty, 1);
// DIAG:      variant_init_err.k:[[@LINE-1]]:5: error [SC064E]: call to 'put' is ambiguous: more than one candidate matches at the same rank
// DIAG-NEXT: variant_init_err.k:[[@LINE-6]]:1: note [I900N]: candidate declared here
// DIAG-NEXT: variant_init_err.k:[[@LINE-6]]:1: note [I900N]: candidate declared here
// DIAG-NEXT: variant_init_err.k:[[@LINE-4]]:5: note [I900N]: conversions are not ordered within a rank; cast one argument to make the choice explicit
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
