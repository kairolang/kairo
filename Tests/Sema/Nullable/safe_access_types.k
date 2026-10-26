// G9 (Compiler/Sema/NULLABLE.md 2.5): the type of `x?.m` / `x?.f()` and
// the errors around it. Each `t_*` initializes a `bool` from one so the
// conversion error names the type it got:
//   - a field `M` is `M?`; a field already `M?` stays `M?`;
//   - a method returning `R` is `R?`; one returning `R?` stays `R?`; a
//     `void` method and a `-> !` one are `void` (on null nothing ran);
//   - `?->` on a `(*Foo)?`, and chains (`a?.b?.c`, `p?->next?->v`);
// and the errors: `?.` / `?->` on a value that is not nullable (SC001E,
// the fix-it drops the `?`), on a name and on a field; the result is an
// rvalue (SC071E on assignment); a step after a `?.` call reads the `R?`
// (`f?.me().v` is R025E: write `?.` again). `?.` needs no check of `f`.

class Inner { pub var w: i32 = 7; pub var tag: i32? = null }
class Foo {
    pub var v: i32 = 1
    pub var n: i32? = null
    pub var inner: Inner? = null
    pub var plain: Inner = Inner()
    pub var next: (*Foo)? = null
    pub fn get(self) -> i32 { return self.v }
    pub fn maybe(self) -> i32? { return self.n }
    pub fn bump(self) { self.v += 1 }
    pub fn die(self) -> ! { while true { } }
    pub fn me(self) -> Foo? { return null }
}

fn t_field(f: Foo?)    { var r: bool = f?.v }
fn t_nfield(f: Foo?)   { var r: bool = f?.n }
fn t_method(f: Foo?)   { var r: bool = f?.get() }
fn t_nmethod(f: Foo?)  { var r: bool = f?.maybe() }
fn t_void(f: Foo?)     { var r: bool = f?.bump() }
fn t_never(f: Foo?)    { var r: bool = f?.die() }
fn t_arrow(p: (*Foo)?) { var r: bool = p?->v }
fn t_chain(f: Foo?)    { var r: bool = f?.inner?.w }
fn t_arrows(p: (*Foo)?) { var r: bool = p?->next?->get() }

fn e_name(f: Foo)      { var r? = f?.v }
fn e_field(f: Foo?)    { var r? = f?.plain?.w }
fn e_ptr(p: *Foo)      { var r? = p?->v }
fn e_assign(f: Foo?)   { f?.v = 3 }
fn e_after(f: Foo?)    { var r = f?.me().v }

fn ok_no_check(f: Foo?) -> i32 { return f?.v ?? 0 }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:27:40: error [SC028E]: cannot convert 'i32?' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:28:40: error [SC028E]: cannot convert 'i32?' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:29:40: error [SC028E]: cannot convert 'i32?' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:30:40: error [SC028E]: cannot convert 'i32?' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:31:40: error [SC028E]: cannot convert 'void' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:32:40: error [SC028E]: cannot convert 'void' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:33:40: error [SC028E]: cannot convert 'i32?' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:34:40: error [SC028E]: cannot convert 'i32?' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:35:41: error [SC028E]: cannot convert 'i32?' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:37:36: error [SC001E]: 'f' is not nullable ('Foo'); '?.' guards a null it cannot hold, write '.'
// DIAG-NEXT: fix-it:{{.*}}:{37:36-37:37}:""
// DIAG-NEXT: safe_access_types.k:37:11: note [{{.*}}]: 'f' is declared 'Foo' here
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:38:43: error [SC001E]: 'f?.plain' is not nullable ('Inner'); '?.' guards a null it cannot hold, write '.'
// DIAG-NEXT: fix-it:{{.*}}:{38:43-38:44}:""
// DIAG-NEXT: safe_access_types.k:18:9: note [{{.*}}]: 'plain' is declared 'Inner' here
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:39:36: error [SC001E]: 'p' is not nullable ('*Foo'); '?->' guards a null it cannot hold, write '->'
// DIAG-NEXT: fix-it:{{.*}}:{39:36-39:37}:""
// DIAG-NEXT: safe_access_types.k:39:10: note [{{.*}}]: 'p' is declared '*Foo' here
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:40:26: error [SC071E]: left side of assignment is not assignable
// DIAG-NOT: {{error|warning}}
// DIAG: safe_access_types.k:41:42: error [R025E]: no member named 'v' in 'Foo?'
// DIAG-NOT: {{error|warning}}
