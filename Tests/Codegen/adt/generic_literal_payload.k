// A literal payload of a generic ADT instance at a type the literal needs a
// conversion to: `Opt<i64>::Some { v: 7 }` passes an int. The
// instance's lambda constructor (`template <class F> Opt(vt<0>, F&&)`) was
// an exact match for the int and beat the field constructor, and C++ then
// called the int ("called object type 'int' is not a function"). The same
// for any builtin argument that converts (an i32 local here). The site
// writes the conversion out, so the field constructor is the exact match.

enum <T> Opt { Some { v: T }, None }

fn get(o: Opt<i64>) -> i64 = match o {
    case .Some(var v) => v
    case .None        => 0
}

fn getf(o: Opt<f64>) -> f64 = match o {
    case .Some(var v) => v
    case .None        => 0.0
}

fn getu(o: Opt<u8>) -> u8 = match o {
    case .Some(var v) => v
    case .None        => 0
}

fn main() -> i32 {
    var a = Opt<i64>::Some { v: 7 }
    var b = Opt<f64>::Some { v: 2 }
    var c = Opt<u8>::Some { v: 3 }
    var n: i32 = 20
    var d = Opt<i64>::Some { v: n }
    var r = get(a) + get(d)
    if getf(b) == 2.0 { r += 10 }
    r += (getu(c) as i64) * 100
    return (r - 300) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 37
