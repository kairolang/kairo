import numlib::*

// Every conversion here is W or I across a module boundary, through a
// generic's deduced or instantiated type, or nested in another call.
fn main() -> i32 {
    var a: i64 = give_i32();               // i32 -> i64 (R1), a result from numlib
    var b = take_i64(give_u32());          // u32 -> i64 (R2), nested
    var c: f64 = pass(give_i32());         // T = i32, then i32 -> f64 (R3)
    var d = take_f64(pass(3.0f32));        // T = f32, then f32 -> f64 (R4)
    var e = Cell<i64>(give_i32());         // i32 -> i64 into an instance's ctor
    e.put(give_u32());                     // u32 -> i64 into an instance's method
    var f: f64 = e.get() as f64 + c;       // E spelled, then f64 + f64
    return (a + b + e.get()) as i32 + (d + f) as i32;
}

// Corpus for Sema/Conversions/module_generic.k (keep this comment last).
