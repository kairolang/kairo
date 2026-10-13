// Building an enum variant: an explicit head (`Shape::Rect { .. }`,
// `Opt<i32>::Some { .. }`), a dotted one whose enum the expected type or the
// parameter names (`.Circle { .. }`), and a variant without a payload written
// alone (`Shape::Empty`, `.Empty`). Each is typed as the enum, and X records
// the variant on the node as written. Nothing renders an ADT construction
// yet, so each is also reported as not supported. A plain enum's `.South` is
// its value, as `Dir::South` is, and is not reported.

enum Shape { Circle { r: i32 }, Rect { w: i32, h: i32 }, Empty }
enum <T> Opt { Some { v: T }, None }
enum Dir { North, South }

fn g() -> i32 { return 3; }
fn consume(s: Shape) { }

fn forms(n: i32) -> Shape {
    var a = Shape::Rect { w: 1, h: 2 };
// DIAG: variant_init.k:[[@LINE-1]]:13: error [SC116E]: building an enum variant is not yet supported
// SEMA: NamedInitializerExpr @ [[@LINE-2]]:13 : Shape [variant=Shape::Rect]
// SEMA-NEXT: ChainExpr @ [[@LINE-3]]:13 : Shape{{$}}
    var b = Shape::Rect { h: g(), w: n };
// DIAG: variant_init.k:[[@LINE-1]]:13: error [SC116E]: building an enum variant is not yet supported
// SEMA: NamedInitializerExpr @ [[@LINE-2]]:13 : Shape [variant=Shape::Rect]
    var c: Shape = .Circle { r: n };
// DIAG: variant_init.k:[[@LINE-1]]:20: error [SC116E]: building an enum variant is not yet supported
// SEMA: NamedInitializerExpr @ [[@LINE-2]]:20 : Shape [variant=Shape::Circle]
    var d: Shape = .Empty;
// DIAG: variant_init.k:[[@LINE-1]]:20: error [SC116E]: building an enum variant is not yet supported
// SEMA: NamedInitializerExpr @ [[@LINE-2]]:20 : Shape [variant=Shape::Empty]
    var e = Shape::Empty;
// DIAG: variant_init.k:[[@LINE-1]]:13: error [SC116E]: building an enum variant is not yet supported
// SEMA: ChainExpr @ [[@LINE-2]]:13 : Shape [variant=Shape::Empty]
    var f = Opt<i32>::Some { v: 7 };
// DIAG: variant_init.k:[[@LINE-1]]:13: error [SC116E]: building an enum variant is not yet supported
// SEMA: NamedInitializerExpr @ [[@LINE-2]]:13 : Opt<i32> [variant=Opt::Some]
    var h: Opt<i32> = .None;
// DIAG: variant_init.k:[[@LINE-1]]:23: error [SC116E]: building an enum variant is not yet supported
// SEMA: NamedInitializerExpr @ [[@LINE-2]]:23 : Opt<i32> [variant=Opt::None]
    var k = Opt<Shape>::Some { v: Shape::Empty };
// DIAG: variant_init.k:[[@LINE-1]]:13: error [SC116E]: building an enum variant is not yet supported
// DIAG: variant_init.k:[[@LINE-2]]:35: error [SC116E]: building an enum variant is not yet supported
// SEMA: NamedInitializerExpr @ [[@LINE-3]]:13 : Opt<Shape> [variant=Opt::Some]
// SEMA: ChainExpr @ [[@LINE-4]]:35 : Shape [variant=Shape::Empty]
    consume(.Circle { r: 2 });
// DIAG: variant_init.k:[[@LINE-1]]:13: error [SC116E]: building an enum variant is not yet supported
// SEMA: NamedInitializerExpr @ [[@LINE-2]]:13 : Shape [variant=Shape::Circle]
    var m: Dir = .South;
// SEMA: NamedInitializerExpr @ [[@LINE-1]]:18 : Dir [variant=Dir::South]
    var q = Dir::North;
// SEMA: ChainExpr @ [[@LINE-1]]:13 : Dir{{$}}
    return .Empty;
// DIAG: variant_init.k:[[@LINE-1]]:12: error [SC116E]: building an enum variant is not yet supported
// SEMA: NamedInitializerExpr @ [[@LINE-2]]:12 : Shape [variant=Shape::Empty]
}

// A dependent expected type that names its enum still resolves `.Some`; the
// field is checked against `T` when the instance is known.
fn <T> wrap(x: T) -> Opt<T> {
    return .Some { v: x };
// DIAG: variant_init.k:[[@LINE-1]]:12: error [SC116E]: building an enum variant is not yet supported
// SEMA: NamedInitializerExpr @ [[@LINE-2]]:12 : Opt<T> [variant=Opt::Some]
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
