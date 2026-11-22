// A `case .V(var x)` binder of a type that cannot be copied takes its
// payload by move when the match owns its scrutinee -- a temporary, or a
// local or by-value parameter -- and an arm moves the binder out: the
// payload leaves the scrutinee where the binder is moved. Over any
// other scrutinee, or when no arm moves it, the binder borrows the payload
// in place. A binder of a type that copies is a copy either way.

enum <K, V> Res { Found { key: K, value: V }, Error { message: string }, Empty }
enum Two { A { s: string }, B { s: string }, C }

fn make(n: i32) -> Res<i32, string> {
    if n > 0 {
        return Res<i32, string>::Found { key: n, value: "found" }
    }

    return Res<i32, string>::Error { message: "err" }
}

fn take(s: string) -> usize { return s.size() }
fn size_of(const r: Res<i32, string>) -> usize = match r {
    case .Found(const value) => value.size()
    default                  => 0
}

// A temporary: bound by value into the match's own local.
fn of_temp(n: i32) -> string = match make(n) {
    case .Found(var value)   => value
    case .Error(var message) => message
    default                  => "none"
}

// A by-value parameter, read for the last time.
fn of_param(r: Res<i32, string>) -> string = match r {
    case .Found(var value) => value
    default                => "none"
}

// A local at its last use, moved out by a `return` in the statement form.
fn of_local(n: i32) -> string {
    var r = make(n)
    match r {
        case .Found(var value) { return value }
        default                { }
    }

    return "none"
}

// Passed on by value from inside the arm.
fn passed(r: Res<i32, string>) -> usize {
    match r {
        case .Found(var value) { return take(value) }
        default                { return 0 }
    }
}

// The payload leaves the parameter where the binder is moved out, not
// where the arm is entered: the read before it sees the whole value.
fn read_then_take(r: Res<i32, string>) -> usize {
    match r {
        case .Found(var value) {
            var n = size_of(r)
            return n + take(value)
        }
        default { return 0 }
    }
}

// Alternatives bind `s` at different payloads: it is read through a slot.
fn either(t: Two) -> string = match t {
    case .A(var s), .B(var s) => s
    default                   => "none"
}

// The binder only reads: it borrows, and the local is read again.
fn reread(n: i32) -> usize {
    var r = make(n)
    var k: usize = 0
    match r {
        case .Found(var value) { k = value.size() }
        default                { }
    }

    match r {
        case .Found(const value) { k += value.size() }
        default                  { }
    }

    return k
}

// A copyable payload is a copy: the local stays whole.
fn keys(n: i32) -> i32 {
    var r = make(n)
    var a: i32 = match r {
        case .Found(var key) => key
        default              => 0
    }

    var b: i32 = match r {
        case .Found(var key) => key + 1
        default              => 0
    }

    return a + b
}

// A constructor pattern inside a tuple pattern, over a tuple local.
fn nested(n: i32) -> string {
    var t = (make(n), 1)
    return match t {
        case (.Found(var value), var k) where k > 0 => value
        default                                     => "none"
    }
}

// A const parameter and a pointer's pointee are not the match's own: the
// binder borrows.
fn peek(const r: Res<i32, string>) -> usize = match r {
    case .Found(var value) => value.size()
    default                => 0
}

fn peek_ptr(p: *Res<i32, string>) -> usize = match *p {
    case .Found(var value) => value.size()
    default                => 0
}

fn main() -> i32 {
    var bad = 0                                 // checks that failed
    if !((of_temp(1).size() == 5) && (of_temp(0).size() == 3)) { bad += 1 }
    if !((of_param(make(2)).size() == 5) && (of_param(Res<i32, string>::Empty).size() == 4)) { bad += 1 }
    if !((of_local(3).size() == 5) && (of_local(0).size() == 4)) { bad += 1 }
    if passed(make(4)) != 5 { bad += 1 }
    if read_then_take(make(8)) != 10 { bad += 1 }
    if !((either(Two::A { s: "ab" }).size() == 2) && (either(Two::B { s: "abc" }).size() == 3)) { bad += 1 }
    if reread(1) != 10 { bad += 1 }
    if keys(5) != 11 { bad += 1 }
    if !((nested(6).size() == 5) && (nested(0).size() == 4)) { bad += 1 }
    var kept = make(7)
    if !((peek(kept) == 5) && (peek_ptr(&kept) == 5) && (peek(kept) == 5)) { bad += 1 }
    return bad
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// An owned scrutinee is read through a mutable reference (a temporary
// through the match's own local), and the binder moves the payload out; a
// binder that only reads, or over storage the match does not own, borrows.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}owned_payload_move.k
// IR-LABEL: of_temp(signed int n) noexcept {
// IR:       Res<signed int, ::builtin::string::string> __kairo_m0_s = {{.*}}make(n);
// IR:       ::builtin::string::string & value = __kairo_m0_s.__kairo_Found.value;
// IR-LABEL: of_param({{.*}} r) noexcept {
// IR:       Res<signed int, ::builtin::string::string> & __kairo_m0_s = r;
// IR:       ::builtin::string::string & value = __kairo_m0_s.__kairo_Found.value;
// IR-NEXT:  (static_cast<{{ ?}}::builtin::string::string{{ ?}}&&>(value));
// IR-LABEL: of_local(signed int n) noexcept {
// IR:       Res<signed int, ::builtin::string::string> & __kairo_m0_s = r;
// IR:       return static_cast<{{ ?}}::builtin::string::string{{ ?}}&&>(value);
// IR-LABEL: read_then_take({{.*}} r) noexcept {
// IR:       ::builtin::string::string & value = __kairo_m0_s.__kairo_Found.value;
// IR:       size_of(r);
// IR:       take(static_cast<{{ ?}}::builtin::string::string{{ ?}}&&>(value))
// IR-LABEL: either({{.*}} t) noexcept {
// IR:       Two & __kairo_m0_s = t;
// IR-NEXT:  ::builtin::string::string * __kairo_m0_p0 {
// IR:       ::builtin::string::string & s ={{ ?}}(* __kairo_m0_p0);
// IR-NEXT:  (static_cast<{{ ?}}::builtin::string::string{{ ?}}&&>(s));
// IR-LABEL: reread(signed int n) noexcept {
// IR:       const{{.*}}Res<signed int, ::builtin::string::string> & __kairo_m0_s = r;
// IR:       const{{ ?}}::builtin::string::string & value = __kairo_m0_s.__kairo_Found.value;
// IR-LABEL: nested(signed int n) noexcept {
// IR:       const{{ ?}}::builtin::string::string & value = __kairo_m0_s._0.__kairo_Found.value;
// IR:       ::builtin::string::string & value = __kairo_m0_s._0.__kairo_Found.value;
// IR-LABEL: peek({{.*}} r) noexcept {
// IR:       const{{.*}}& __kairo_m0_s = r;
// IR:       const{{ ?}}::builtin::string::string & value = __kairo_m0_s.__kairo_Found.value;
// IR-LABEL: peek_ptr({{.*}} p) noexcept {
// IR:       const{{.*}}& __kairo_m0_s ={{ ?}}(* p);
// IR:       const{{ ?}}::builtin::string::string & value = __kairo_m0_s.__kairo_Found.value;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
