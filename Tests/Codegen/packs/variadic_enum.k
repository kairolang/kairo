// A variadic enum: `Err { error: E }...` is one variant per element of the
// pack E, told apart by payload type in construction and in patterns. Equal
// types in the pack are one variant (`Outcome<i32, string, string>` IS
// `Outcome<i32, string>`), an empty pack leaves only the ordinary variants,
// and the special members copy, move and destroy exactly the live element.

var copies: i32 = 0
var drops: i32 = 0

class Cp {
    pub var id: i32
    pub fn Cp(self, id: i32) { self.id = id; }
    @copy fn Cp(self, const other: Self) { self.id = other.id; copies = copies + 1; }
    fn op delete(self) { drops = drops + 1; }
}

enum <T, ...E> Outcome {
    Ok  { value: T },
    Err { error: E }...,
}

fn describe(o: Outcome<i32, string, f64>) -> i32 = match o {
    case .Ok(var value)          => value
    case .Err(var error: string) => error.len as i32
    case .Err(var error: f64)    => 100
}

fn holds_cp(const o: Outcome<i32, f64, Cp>) -> i32 = match o {
    case .Err(const error: Cp) => error.id
    default                    => -1
}

fn only(o: Outcome<bool, i64>) -> i64 = match o {
    case .Ok        => 0
    case .Err(var error) => error                // one element: no type needed
}

fn plain(o: Outcome<i32>) -> i32 = match o {
    case .Ok(var value) => value
}

fn lifecycle() -> bool {
    var a = Outcome<i32, f64, Cp>::Err { error: Cp(7) }
    copies = 0; drops = 0
    var b = a                                    // the Cp element copied
    if (copies != 1) || (holds_cp(b) != 7) { return false }
    b = Outcome<i32, f64, Cp>::Err { error: 2.5 } // the old Cp destroyed, a trivial element built
    if drops != 1 { return false }
    var c: Outcome<i32, f64, Cp> = .Ok { value: 3 }
    c = a                                        // copied in, nothing destroyed
    return (copies == 2) && (drops == 1) && (holds_cp(c) == 7) && (holds_cp(b) == -1)
}

fn main() -> i32 {
    var a: Outcome<i32, string, f64> = .Ok { value: 1 }
    var b: Outcome<i32, string, f64> = .Err { error: "hello" }
    var d = Outcome<i32, string, f64, string>::Err { error: 1.5 }   // the same type as b's
    var e = b
    e = d
    var r = describe(a) + describe(b) + describe(d) + describe(e)  // 1 + 5 + 100 + 100
    if only(Outcome<bool, i64>::Err { error: 4 }) != 4 { r += 1000 }
    if plain(.Ok { value: 9 }) != 9 { r += 1000 }
    if !lifecycle() { r += 2000 }
    if describe(relay(b)) != 5 { r += 4000 }
    return r - 200                               // 6
}

// A generic function over the pack: E deduces from the argument's type,
// and the C++ template takes the instance whole.
fn <...E> relay(o: Outcome<i32, E...>) -> Outcome<i32, E...> { return o }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The decision tree tests each element as its own constructor.
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA:      SEMA fid {{[0-9]+}}: {{.*}}variadic_enum.k
// SEMA:      MatchExpr @ 22:52 {{.*}}[exhaustive=1
// SEMA:        {{n[0-9]+}}: switch $ { .Ok => {{n[0-9]+}}, .Err(var error: string) => {{n[0-9]+}}, .Err(var error: f64) => {{n[0-9]+}}, _ => unmatched }
// SEMA:        {{n[0-9]+}}: leaf arm 1 [error=$.Err[0].error]

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<class T, class ... E> struct Outcome {
// CXX: template<class __kairo_pe> struct __kairo_Err_t {
// CXX: __kairo_pe error;
// CXX: ::__kairo_pu<__kairo_Err_t<E> ...> __kairo_Err;
// CXX: template<unsigned int K, class F> Outcome( ::__kairo_vt<1>, ::__kairo_vt<K>, F && f) noexcept: __kairo_tag(static_cast<__kairo_Tag>(1 + K)), __kairo_Err( ::__kairo_vt<K> {
// CXX: double error = __kairo_m{{[0-9]+}}_s.__kairo_Err.template __kairo_get<1>().error;
// CXX: ::variadic_enum::relay< ::builtin::string::string, double>(b)
// CXX: template<class ... E>::variadic_enum::Outcome<signed int, E ...> relay( ::variadic_enum::Outcome<signed int, E ...> o) noexcept {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
