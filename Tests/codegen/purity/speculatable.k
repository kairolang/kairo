// `__builtin_fn_speculatable(const &f)`: whether the `fn` value says its
// function may be evaluated on arguments the program never passed it. The
// compiler says so, in a value made from the function's name, for a
// predicate (a `bool` result) with a purity level (written or inferred), a
// termination proof, and a body that does none of three things. It does not
// stop the program: no integer `/` or `%` by anything but a nonzero literal,
// no index the language does not check through an operator, no `unsafe`, no
// `assume`, no call of a function that is not speculatable itself. It reads
// through no pointer its arguments do not reach: every dereference is of a
// path from a parameter, a callee is handed only such paths and numbers,
// nothing but a number is assigned, and no global but a number is read; so a
// stepped pointer (`*(*p + 1)`, which safe code may write unchecked), a
// pointer held in a local and a pointer a callee returns are never read
// through. And it does not loop, so the work of a call is bounded by the
// program's text. The fact follows the value through copies and parameters;
// a closure and a value made any other way say no.

import std::io

var total: i32 = 0
var table: [i32; 4] = [1, 2, 3, 4]

struct Limits {
    var low: i32
    var at: *const i32
}

var limits: Limits = Limits { low: 3, at: &total }

fn clean(p: *const i32) -> bool = *p > 3
fn written(x: i32) const -> bool { return x * 2 > 10 }
@pure fn reads_global(p: *const i32) -> bool { return *p > total }
fn calls_clean(p: *const i32) -> bool = clean(p) && *p < 100
fn literal_divisor(p: *const i32) -> bool = *p % 2 == 0 && *p / 3 > 1
fn float_divisor(p: *const f64) -> bool = 1.0 / *p > 0.5
fn hinted(p: *const i32) -> bool = __builtin_expect(*p > 3, true)
fn ranged(p: *const i32) -> bool {
    var s = 0
    for i in 0..4 { s += *p + i }
    return s > 10
}

fn divides(p: *const i32) -> bool = 100 / *p > 3
fn remainder(p: *const i32) -> bool = 100 % *p == 1
fn divides_by_zero_literal(p: *const i32) -> bool = *p / 0 > 3
fn divide_assigns(p: *const i32) -> bool {
    var x = 100
    x /= *p
    return x > 3
}
fn indexes(p: *const i32) -> bool = table[(*p & 3) as usize] > 2
fn unsafe_read(p: *const i32) -> bool {
    unsafe {
        var unsafe *q = p as unsafe *const i32
        return *q > 3
    }
}
fn writes(p: *const i32) -> bool {
    total += 1
    return *p > 3
}
fn loops(p: *const i32) -> bool {
    var i = 0
    while i != *p { i += 1 }
    return i > 3
}
fn calls_divides(p: *const i32) -> bool = divides(p) || *p == 7
fn doubled(x: i32) -> i32 = x * 2
@pure fn follows_global(p: *const i32) -> bool { return *p > *limits.at }
@pure fn reads_record_global(p: *const i32) -> bool { return *p > limits.low }
fn assumes(p: *const i32) -> bool {
    @assume(*p != 0)
    return *p > 3
}


struct Cell {
    var v: i32
    var at: *const i32
}

// A pointer the argument does not reach: stepped, held in a local, never
// set, or handed back by a callee.
fn reads_next(p: *const (*const i32)) -> bool = **p + *(*p + 1) == 15
fn reads_previous(p: *const (*const i32)) -> bool = **p + *(*p - 1) == 15
fn steps_copy(p: *const (*const i32)) -> bool {
    var q = *p
    q += 1
    return *q > 3
}
fn steps_copy_back(p: *const (*const i32)) -> bool {
    var q = *p
    q -= 1
    return *q > 3
}
fn increments_copy(p: *const (*const i32)) -> bool {
    var q = *p
    ++q
    return *q > 3
}
fn post_increments_copy(p: *const (*const i32)) -> bool {
    var q = *p
    q++
    return *q > 3
}
fn stepped(q: *const i32) -> *const i32 = q + 1
fn reads_stepped(p: *const (*const i32)) -> bool = *stepped(*p) > 3
fn passes_stepped(p: *const (*const i32)) -> bool = clean(*p + 1)
fn reads_copy(p: *const (*const i32)) -> bool {
    var q = *p
    return *q > 3
}
fn reads_unset(p: *const (*const i32)) -> bool {
    var q: *const i32
    if **p > 100 {
        return *q > 3
    }

    return false
}
fn reads_unset_field(p: *const (*const i32)) -> bool {
    var c = Cell { v: 1 }
    if **p > 100 {
        return *c.at > 3
    }

    return false
}

// A path from the argument, and the address of a number.
fn reads_twice(p: *const (*const i32)) -> bool = **p > 3
fn reads_field(c: *const Cell) -> bool = c->v > 3
fn follows_field(c: *const Cell) -> bool = *c->at > 3
fn passes_argument(p: *const (*const i32)) -> bool = clean(*p)
fn passes_number_address(p: *const i32) -> bool {
    var x = *p * 2
    return clean(const &x)
}

// A loop a value bounds: the call returns, after as long as the value says.
fn value_loop(p: *const i64) -> bool {
    var s: i64 = 0
    for i in 0..*p { s += i }
    return s > 10
}
fn sum_to(x: i64) -> i64 {
    var s: i64 = 0
    for i in 0..x { s += i }
    return s
}
fn calls_value_loop(p: *const i64) -> bool = *p == 7 || sum_to(*p) > 3

// `-1` is not a literal: the divisor is an expression.
fn minus_one_divisor(p: *const i32) -> bool = *p / -1 > 3

fn ask(f: fn(*const i32) -> bool) -> bool = __builtin_fn_speculatable(const &f)

fn say(const name: string, yes: bool) {
    io::println(f"{name}={if yes => 1 else => 0}")
}

fn main() -> i32 {
    var f_clean: fn(*const i32) -> bool = clean
    var f_written: fn(i32) -> bool = written
    var f_reads_global: fn(*const i32) -> bool = reads_global
    var f_calls_clean: fn(*const i32) -> bool = calls_clean
    var f_literal_divisor: fn(*const i32) -> bool = literal_divisor
    var f_float_divisor: fn(*const f64) -> bool = float_divisor
    var f_hinted: fn(*const i32) -> bool = hinted
    var f_ranged: fn(*const i32) -> bool = ranged
    say("clean", __builtin_fn_speculatable(const &f_clean))
    say("written", __builtin_fn_speculatable(const &f_written))
    say("reads_global", __builtin_fn_speculatable(const &f_reads_global))
    say("calls_clean", __builtin_fn_speculatable(const &f_calls_clean))
    say("literal_divisor", __builtin_fn_speculatable(const &f_literal_divisor))
    say("float_divisor", __builtin_fn_speculatable(const &f_float_divisor))
    say("hinted", __builtin_fn_speculatable(const &f_hinted))
    say("ranged", __builtin_fn_speculatable(const &f_ranged))

    var f_divides: fn(*const i32) -> bool = divides
    var f_remainder: fn(*const i32) -> bool = remainder
    var f_zero: fn(*const i32) -> bool = divides_by_zero_literal
    var f_divide_assigns: fn(*const i32) -> bool = divide_assigns
    var f_indexes: fn(*const i32) -> bool = indexes
    var f_unsafe_read: fn(*const i32) -> bool = unsafe_read
    var f_writes: fn(*const i32) -> bool = writes
    var f_loops: fn(*const i32) -> bool = loops
    var f_calls_divides: fn(*const i32) -> bool = calls_divides
    var f_assumes: fn(*const i32) -> bool = assumes
    var f_doubled: fn(i32) -> i32 = doubled
    var f_follows_global: fn(*const i32) -> bool = follows_global
    var f_reads_record_global: fn(*const i32) -> bool = reads_record_global
    say("divides", __builtin_fn_speculatable(const &f_divides))
    say("remainder", __builtin_fn_speculatable(const &f_remainder))
    say("divides_by_zero_literal", __builtin_fn_speculatable(const &f_zero))
    say("divide_assigns", __builtin_fn_speculatable(const &f_divide_assigns))
    say("indexes", __builtin_fn_speculatable(const &f_indexes))
    say("unsafe_read", __builtin_fn_speculatable(const &f_unsafe_read))
    say("writes", __builtin_fn_speculatable(const &f_writes))
    say("loops", __builtin_fn_speculatable(const &f_loops))
    say("calls_divides", __builtin_fn_speculatable(const &f_calls_divides))
    say("assumes", __builtin_fn_speculatable(const &f_assumes))
    say("doubled", __builtin_fn_speculatable(const &f_doubled))
    say("follows_global", __builtin_fn_speculatable(const &f_follows_global))
    say("reads_record_global", __builtin_fn_speculatable(const &f_reads_record_global))

    var f_reads_next: fn(*const (*const i32)) -> bool = reads_next
    var f_reads_previous: fn(*const (*const i32)) -> bool = reads_previous
    var f_steps_copy: fn(*const (*const i32)) -> bool = steps_copy
    var f_steps_copy_back: fn(*const (*const i32)) -> bool = steps_copy_back
    var f_increments_copy: fn(*const (*const i32)) -> bool = increments_copy
    var f_post_increments_copy: fn(*const (*const i32)) -> bool = post_increments_copy
    var f_reads_stepped: fn(*const (*const i32)) -> bool = reads_stepped
    var f_passes_stepped: fn(*const (*const i32)) -> bool = passes_stepped
    var f_reads_copy: fn(*const (*const i32)) -> bool = reads_copy
    var f_reads_unset: fn(*const (*const i32)) -> bool = reads_unset
    var f_reads_unset_field: fn(*const (*const i32)) -> bool = reads_unset_field
    say("reads_next", __builtin_fn_speculatable(const &f_reads_next))
    say("reads_previous", __builtin_fn_speculatable(const &f_reads_previous))
    say("steps_copy", __builtin_fn_speculatable(const &f_steps_copy))
    say("steps_copy_back", __builtin_fn_speculatable(const &f_steps_copy_back))
    say("increments_copy", __builtin_fn_speculatable(const &f_increments_copy))
    say("post_increments_copy", __builtin_fn_speculatable(const &f_post_increments_copy))
    say("reads_stepped", __builtin_fn_speculatable(const &f_reads_stepped))
    say("passes_stepped", __builtin_fn_speculatable(const &f_passes_stepped))
    say("reads_copy", __builtin_fn_speculatable(const &f_reads_copy))
    say("reads_unset", __builtin_fn_speculatable(const &f_reads_unset))
    say("reads_unset_field", __builtin_fn_speculatable(const &f_reads_unset_field))

    var f_reads_twice: fn(*const (*const i32)) -> bool = reads_twice
    var f_reads_field: fn(*const Cell) -> bool = reads_field
    var f_follows_field: fn(*const Cell) -> bool = follows_field
    var f_passes_argument: fn(*const (*const i32)) -> bool = passes_argument
    var f_passes_number_address: fn(*const i32) -> bool = passes_number_address
    say("reads_twice", __builtin_fn_speculatable(const &f_reads_twice))
    say("reads_field", __builtin_fn_speculatable(const &f_reads_field))
    say("follows_field", __builtin_fn_speculatable(const &f_follows_field))
    say("passes_argument", __builtin_fn_speculatable(const &f_passes_argument))
    say("passes_number_address", __builtin_fn_speculatable(const &f_passes_number_address))

    var f_value_loop: fn(*const i64) -> bool = value_loop
    var f_calls_value_loop: fn(*const i64) -> bool = calls_value_loop
    var f_minus_one_divisor: fn(*const i32) -> bool = minus_one_divisor
    say("value_loop", __builtin_fn_speculatable(const &f_value_loop))
    say("calls_value_loop", __builtin_fn_speculatable(const &f_calls_value_loop))
    say("minus_one_divisor", __builtin_fn_speculatable(const &f_minus_one_divisor))

    // The fact is the value's: a copy keeps it, an assignment replaces it,
    // and a parameter receives it.
    var copy = f_clean
    say("copy", __builtin_fn_speculatable(const &copy))
    copy = f_divides
    say("reassigned", __builtin_fn_speculatable(const &copy))
    say("argument", ask(clean))
    say("argument_divides", ask(divides))
    say("argument_copy", ask(f_clean))

    // A closure makes no promise, whatever its body.
    var closure: fn(*const i32) -> bool = fn (p: *const i32) -> bool = *p > 3
    var bound = 3
    var capturing: fn(*const i32) -> bool = fn (p: *const i32) -> bool = *p > bound
    say("closure", __builtin_fn_speculatable(const &closure))
    say("capturing", __builtin_fn_speculatable(const &capturing))

    // Every one of them is still the function it names.
    var three = 3
    var nine = 9
    if f_clean(const &three) || !f_clean(const &nine) || !copy(const &nine) || !closure(const &nine) || !capturing(const &nine) {
        return 1
    }

    if !f_written(6) || !f_reads_global(const &nine) || !f_indexes(const &three) || !f_unsafe_read(const &nine) {
        return 2
    }

    return 0
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.O2.exe %t.off.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe | %FileCheck %s --check-prefixes=ALL,INFER
// RUN: %kairo %s -O2 -o %t.O2.exe --cache-dir %t.d/o2
// RUN: %t.O2.exe | %FileCheck %s --check-prefixes=ALL,INFER
// ALL-DAG: written=1
// ALL-DAG: reads_global=1
// INFER-DAG: clean=1
// INFER-DAG: calls_clean=1
// INFER-DAG: literal_divisor=1
// INFER-DAG: float_divisor=1
// INFER-DAG: hinted=1
// INFER-DAG: reads_twice=1
// INFER-DAG: reads_field=1
// INFER-DAG: follows_field=1
// INFER-DAG: passes_argument=1
// INFER-DAG: passes_number_address=1
// ALL-DAG: ranged=0
// ALL-DAG: reads_next=0
// ALL-DAG: reads_previous=0
// ALL-DAG: steps_copy=0
// ALL-DAG: steps_copy_back=0
// ALL-DAG: increments_copy=0
// ALL-DAG: post_increments_copy=0
// ALL-DAG: reads_stepped=0
// ALL-DAG: passes_stepped=0
// ALL-DAG: reads_copy=0
// ALL-DAG: reads_unset=0
// ALL-DAG: reads_unset_field=0
// ALL-DAG: value_loop=0
// ALL-DAG: calls_value_loop=0
// ALL-DAG: minus_one_divisor=0
// ALL-DAG: divides=0
// ALL-DAG: remainder=0
// ALL-DAG: divides_by_zero_literal=0
// ALL-DAG: divide_assigns=0
// ALL-DAG: indexes=0
// ALL-DAG: unsafe_read=0
// ALL-DAG: writes=0
// ALL-DAG: loops=0
// ALL-DAG: calls_divides=0
// ALL-DAG: assumes=0
// ALL-DAG: doubled=0
// ALL-DAG: follows_global=0
// ALL-DAG: reads_record_global=0
// INFER-DAG: copy=1
// ALL-DAG: reassigned=0
// INFER-DAG: argument=1
// ALL-DAG: argument_divides=0
// INFER-DAG: argument_copy=1
// ALL-DAG: closure=0
// ALL-DAG: capturing=0

// Without inference only a written promise has a level.
// RUN: %kairo %s -fno-infer-purity -o %t.off.exe --cache-dir %t.d/off
// RUN: %t.off.exe | %FileCheck %s --check-prefixes=ALL,OFF
// OFF-DAG: clean=0
// OFF-DAG: calls_clean=0
// OFF-DAG: argument=0

// The value says so where it is made from the name, and nowhere else.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX --implicit-check-not='divides, ::__kairo_spec' --implicit-check-not='doubled, ::__kairo_spec'
// CXX-DAG: f_clean = ::__kairo_fn<bool(const signed int *)>( {{.*}}clean, ::__kairo_spec
// CXX-DAG: ask( ::__kairo_fn<bool(const signed int *)>( {{.*}}clean, ::__kairo_spec
// CXX-DAG: f_divides = static_cast< ::__kairo_fn<bool(const signed int *)>>( {{.*}}divides);
