// A generic body is checked once, against its bounds (generics.mdx, MONO.md
// D0). An operator, a conversion, an interpolation, a null test or a pattern
// on a value of an opaque parameter `T` is something only a bound can grant,
// so each is an error AT THE DEFINITION, naming what would grant it, never
// a C++ error at some instance (or none, if the template is never used).
// Under `-fduck-generics` a `: type` parameter keeps the C++ rule: nothing
// is said here, and C++ checks each instance.

pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}

// --- unbounded: the parameter promised nothing --------------------------------

fn <T> eq(a: T, b: T) -> bool = a == b
// DIAG: opaque_param_ops.k:[[@LINE-1]]:33: error [R051E]: '==' on 'T' needs a bound that declares 'op =='
// DIAG-NEXT: opaque_param_ops.k:[[@LINE-2]]:5: note [R051N]: 'T' is declared with no bound

fn <T> ne(a: T, b: T) -> bool = a != b
// DIAG: opaque_param_ops.k:[[@LINE-1]]:33: error [R051E]: '!=' on 'T' needs a bound that declares 'op !=' or 'op =='

fn <T> lt(a: T, b: T) -> bool = a < b
// DIAG: opaque_param_ops.k:[[@LINE-1]]:33: error [R051E]: '<' on 'T' needs a bound that declares 'op <' or 'op <=>'

fn <T> add(a: T, b: T) -> T = a + b
// DIAG: opaque_param_ops.k:[[@LINE-1]]:31: error [R051E]: '+' on 'T' needs a bound that declares 'op +' or 'op +='

// The right operand is no excuse: Kairo's operators are the left operand's,
// and an `i32` has no `+` taking a `T`.
fn <T> radd(a: i32, b: T) -> i32 = a + b
// DIAG: opaque_param_ops.k:[[@LINE-1]]:36: error [R051E]: '+' on 'T' needs a bound that declares 'op +' or 'op +='

fn <T> neg(a: T) -> T = -a
// DIAG: opaque_param_ops.k:[[@LINE-1]]:25: error [R051E]: '-' on 'T' needs a bound that declares 'op -'

fn <T> bump(a: T, b: T) {
    var x = a
    x += b
}
// DIAG: opaque_param_ops.k:[[@LINE-2]]:5: error [R051E]: '+=' on 'T' needs a bound that declares 'op +=' or 'op +'

fn <T> power(a: T) -> T = a ^^ 2
// DIAG: opaque_param_ops.k:[[@LINE-1]]:27: error [R051E]: '^^' on 'T' needs a bound that declares 'op ^^'

// `===` compares the values with their `==` (nullables.mdx), so it needs one
// on T; nothing about T says it is a pointer, so there is no pointee rule
// to fall back on either.
fn <T> same(a: T?, b: T?) -> bool = a === b
// DIAG: opaque_param_ops.k:[[@LINE-1]]:37: error [R051E]: '===' on 'T?' compares the values with 'op ==', so it needs a bound on 'T' that declares 'op =='

// Only a `T?` can be null: whatever T is instantiated with, the body sees a T.
fn <T> isnull(a: T) -> bool = a == null
// DIAG: opaque_param_ops.k:[[@LINE-1]]:31: error [SC001E]: 'a' is not nullable; 'T' is never null, so comparing it with 'null' is meaningless
fn <T> present(a: T) -> bool = a?
// DIAG: opaque_param_ops.k:[[@LINE-1]]:32: error [SC066E]: 'a' is not nullable; '?' tests a nullable, and 'T' is never null

fn <T> text(a: T) -> string = a as string
// DIAG: opaque_param_ops.k:[[@LINE-1]]:31: error [R051E]: 'as string' on 'T' needs a bound that declares 'op as' returning 'string'

fn <T> shown(a: T) -> string = f"<{a}>"
// DIAG: opaque_param_ops.k:[[@LINE-1]]:36: error [R051E]: formatting a 'T' needs a bound that declares 'fn repr(self) -> string' or 'op as' returning 'string'

// A pattern can only bind it, or not look at it: T has no variants, no
// values a literal could equal, no fields.
fn <T> pick(a: T) -> i32 {
    return match a {
        case 1 => 1
        case var x where true => 2
        case _ => 3
    }
}
// DIAG: opaque_param_ops.k:[[@LINE-5]]:14: error [SC001E]: a value of type 'T' can only be matched by a binding, '_' or 'default' (with a 'where' guard)

// Exhaustive only when an unguarded binder or `_` ends it, as for any type
// whose values no pattern can list.
fn <T> guarded(a: T, k: i32) -> i32 {
    return match a {
        case var x where k > 0 => 1
    }
}
// DIAG: opaque_param_ops.k:[[@LINE-4]]:12: error [SC120E]: match is not exhaustive: 'T' values other than the ones listed are not covered

// A generic ADT at a dependent argument is no opaque T: its variants are
// known, so its match is checked here like any other.
enum <T> Rep {
    Some { v: T },
    None,
}
fn <T> some_only(r: Rep<T>) -> i32 {
    return match r {
        case .Some(const v) => 1
    }
}
// DIAG: opaque_param_ops.k:[[@LINE-4]]:12: error [SC120E]: match is not exhaustive{{.*}}

// --- bounded, but not by anything that declares it ----------------------------

fn <T impl Scalable> beq(a: T, b: T) -> bool = a == b
// DIAG: opaque_param_ops.k:[[@LINE-1]]:48: error [R025E]: '==' on 'T' needs a bound that declares 'op =='; none of the bounds of 'T' does

fn <T impl Scalable> btext(a: T) -> string = a as string
// DIAG: opaque_param_ops.k:[[@LINE-1]]:46: error [R025E]: 'as string' on 'T' needs a bound that declares 'op as' returning 'string'; none of the bounds of 'T' does

fn <T impl Scalable> bshown(a: T) -> string = f"{a}"
// DIAG: opaque_param_ops.k:[[@LINE-1]]:50: error [R025E]: formatting a 'T' needs a bound that declares 'fn repr(self) -> string' or 'op as' returning 'string'; none of the bounds of 'T' does

// The bound's own requirements still work, and so does what needs no bound:
// `&a`, a pointer compare, `t?` on a `T?`.
fn <T impl Scalable> fine(a: T, b: T?, p: *T, q: *T) -> bool {
    var r = a.scale(2)
    var s = &a
    return (p == q) && b? && (r > 0)
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
//
// The same bodies under `: type` are C++'s to check: no diagnostic at all
// (MONO.md D1). Its `as string` and interpolations keep their old refusals,
// so they are left out of the copy.
// RUN: sed -e 's/fn <T>/fn <T: type>/' -e 's/fn <T impl Scalable>/fn <T: type>/' -e '/as string/d' -e '/f"/d' %s > %t.k
// Only the generic ADT's match keeps its error: its variants are known
// whatever kind of parameter it is instantiated at.
// RUN: { %kairo %t.k --type-check-only -fduck-generics 2>&1 || true; } | %FileCheck %s --check-prefix=DUCK --implicit-check-not=error
// DUCK: error [SC120E]: match is not exhaustive: '.None' is not covered
