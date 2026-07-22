// ============================================================================
//  Symbol-table WALK stress test.
//
//  Purpose: verify _build_symbols picks up every CONSTRUCTIBLE decl form into
//  the correct cell in the correct scope, with nothing silently dropped.
//  This is NOT an N(a) test: fwd/def stay UNLINKED, specializations stay
//  UNGROUPED, extension members stay in the extension's OWN table. That raw
//  pre-N(a) state is exactly what we want to eyeball.
//
//  Run:
//    kairo test.k --print-ast=flat --print-symbols --syntax-only
//
//  Read the SYMBOLS dump against the EXPECT comments below.
// ============================================================================


// --- 1. TU-level fwd decl + definition (redecl pair, UNLINKED) --------------
// EXPECT scope <tu>: one cell `fwd_then_def` with [overloaded x2] holding the
// bodyless fwd decl AND the definition, side by side, no prev-link (N(a)'s job).
fn fwd_then_def() -> i32
fn fwd_then_def() -> i32 { return 0 }


// --- 2. TU-level overload set (distinct signatures, same name) --------------
// EXPECT scope <tu>: cell `over` [overloaded x2].
fn over(x: i32) -> i32 { return x }
fn over(x: u32) -> u32 { return x }


// --- 3. Generic primary + explicit/partial specializations (UNGROUPED) ------
// EXPECT scope <tu>: `Box` cell holds primary + BOTH specializations piled
// together (3 decls), NOT grouped under the primary. `sum` similarly.
class <T> Box { var v: T }
class <> Box<i32> { var v: i32 }
class <> Box<[T]> { var v: T }

fn <T impl Numeric> sum(items: [T]) -> T
fn <> sum<i32>(items: [i32]) -> i32 { return 0 }


// --- 4. Type aliases, generic + plain --------------------------------------
// EXPECT scope <tu>: cells `AliasG` and `AliasP` (idents).
type <T> AliasG = std::vec<T>
type AliasP     = u32


// --- 5. Enum with variants --------------------------------------------------
// EXPECT scope <tu>: `Dir` (ident). scope <tu>::Dir: `North`,`South` variants
// keyed in the enum's own table (per-segment resolution).
enum Dir derives u8 {
    North
    South
}


// --- 6. Interface (methods = requirement signatures, bodyless) --------------
// EXPECT scope <tu>: `Shape`. scope <tu>::Shape: `area` (bodyless sig still
// lands as a member cell).
interface Shape {
    fn area(self) -> u32
}


// --- 7. Full OOP class: ctor, operators, method, nested type ---------------
// EXPECT scope <tu>: `Widget`. scope <tu>::Widget: `Widget`(ctor via
// DeclName::ctor), `op +`, `op []` (distinct operator cells, names rendered
// from op_token), `render` (method), `Inner` (nested type). => 5 names.
// EXPECT scope <tu>::Widget::Inner: `deep`.
class Widget {
    var w: u32

    fn Widget(self) {}

    static fn op + (other: i32) {}
    fn op [] (idx: u32) {}

    fn render(self) {}

    class Inner {
        fn deep(self) {}
    }
}


// --- 8. Struct (fields + nested type only; methods rejected at parse) --------
// EXPECT scope <tu>: `Point`. scope <tu>::Point: `x`,`y` fields, `Meta` nested.
struct Point {
    var x: i32
    var y: i32

    struct Meta { var tag: u8 }
}


// --- 9. Union (fields only) -------------------------------------------------
// EXPECT scope <tu>: `Bits`. scope <tu>::Bits: `as_u32`,`as_f32`.
union Bits {
    var as_u32: u32
    var as_f32: f32
}


// --- 10. Extension members (own table, UNMERGED into target) ----------------
// EXPECT: a separate extension scope whose table holds `scaled`. Folding into
// Widget is sema's job, not the walk's. NOTE: extension has no name; the walk
// renders its scope header as <extension>.
extend Widget {
    fn scaled(self) -> u32 { return 0 }
}


// --- 11. Module (named scope) -----------------------------------------------
// EXPECT scope <tu>: `geo`. scope <tu>::geo: `helper`.
module geo {
    fn helper() -> i32 { return 1 }
}


// --- 12. Visibility group (PASSTHROUGH: members land in enclosing table) ----
// EXPECT scope <tu>: `exported_a`,`exported_b` appear DIRECTLY at <tu>, NOT
// under a group scope (visibility groups own no table).
pub {
    fn exported_a() {}
    fn exported_b() {}
}


// --- 13. eval block (PASSTHROUGH) ------------------------------------------
// EXPECT scope <tu>: `eval_fn` at <tu> level.
eval {
    fn eval_fn() {}
}


// --- 14. ffi block (PASSTHROUGH, FFILinkage stamped) ------------------------
// EXPECT scope <tu>: `c_call` at <tu> level.
ffi "c" {
    fn c_call() -> i32
}


// --- 15. Proc macro WITH body (now parses; was ICE) -------------------------
// EXPECT: parses cleanly (no crash). Where it lands in the dump is the OPEN
// question (line-734 fallthrough currently DROPS it) eyeball whether
// `expand` shows at <tu> or is absent. That absence, if present, is the
// documented pre-decision drop, not a walk bug.
macro @expand(node: *ast::Decl) {
    return node
}


// --- 16. Top-level bindings (DeclStmt sweep) --------------------------------
// EXPECT scope <tu>: `g_var`,`g_const` (picked up via the program->items
// DeclStmt path, not dc_decls).
var   g_var   = 10
const g_const = 20
