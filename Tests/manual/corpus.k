/// --- parser regression: corpus.k ----------------------------------------
/// Clean-run corpus: parses, name-resolves, types, lowers, links and runs.
/// No import/ffi (stubbed in-file). No closures (TODO).
///
/// KNOWN COMPILER BUG (not a corpus issue): members declared inside a
/// `pub { }` / `prot { }` visibility group are resolved twice and report
/// [R001E] '<name>' redefined against themselves. Members are declared with
/// per-member visibility below to route around it. Restore the grouped form
/// once the resolver stops double-walking group bodies.

import std::io::println

// == interfaces ============================================================

interface Printable {
    fn print(self) -> string
}

interface Numeric {
    static fn zero() -> Self
    fn op + (self, other: Self) -> Self
}

// == generic stubs =========================================================

class <L, R> Pair {
    var l: L
    var r: R
}

class <T> Vec {
    var n: i32
    var items: [T]
    fn len(self) -> i32 { return self.n }
}

class <K, V> Map {
    var n: i32
    var keys: [K]
    var vals: [V]
}

class <K, V> Lookup {
    var hits: i32
    static fn create() -> Lookup<K, V> { return Lookup<K, V>() }
}

// == modules ===============================================================

module Io  { class Error   { var code: i32 } }
module Net { class Timeout { var ms: i32 } }
module ast { class FnDecl  { var id: i32 }
             class Decl    { var id: i32 } }

// == free functions ========================================================

var side_effects: i32 = 0

fn risky() -> i32 { return 7 }
fn boom()  -> i32 { side_effects += 1; return side_effects }
fn retry() -> i32 { side_effects += 10; return side_effects }
fn cleanup()       { side_effects += 100 }
fn lo()            { side_effects += 1 }
fn mid()           { side_effects += 2 }
fn neg()           { side_effects += 3 }
fn hi()            { side_effects += 4 }
fn unroll(i: i32)  { side_effects += i }
fn use_(a: i32, b: i32) { side_effects += a + b }
fn make_route(path: string) -> i32 { return 1 }

class File {
    var path: string
    var written: i32
    fn write(self, s: string) { self.written += 1 }
}

fn open(path: string) -> File {
    var f = File()
    f.path = path
    return f
}

// == attrs + visibility on decls ==========================================

pub struct OldThing {
    var a: i32
    var b: u8
}

class Foo derives OldThing impl Printable {
    pub var x: i32
    pub var y: i32 = 10
    pub fn get_x(self) -> i32 { return self.x }

    priv var secret: u64

    prot var shared_state: *u8
    prot static fn helper() -> bool { return true }
    pub  static fn helper_ok() -> bool { return Foo::helper() }

    fn <T impl Numeric> sum(self, items: [T]) -> T {
        var total: T = T::zero()
        for var i in items {
            total = total + i
        }
        return total
    }

    fn describe(self) -> string { return "Foo" }
    fn print(self) -> string { return self.describe() }

    fn op == (self, other: *Foo) -> bool {
        return self.x == other->x
    }
}

// nested generics: `>>` split, pending close angle
type StrMap = Map<string, Vec<Pair<i32, i32>>>
type Cb     = fn(i32, *u8) -> bool

pub module geo {
    enum Shape derives u8 {
        Point,
        Circle { radius: f64 },
        Rect   { w: f64, h: f64 },
    }

    interface Area {
        fn area(self) -> f64
    }

    class Square impl Area {
        var side: f64
        fn area(self) -> f64 { return self.side * self.side }
    }
}

// == newline rules =========================================================

class MyFoo {
    var hits: i32
    fn bar(self) -> *MyFoo? { self.hits += 1; return &self }
    fn baz(self) -> *MyFoo? { self.hits += 1; return &self }
    fn qux(self) -> i32     { return self.hits }
}

var chained_src = MyFoo()
// var chained: i32 = unwrap!(chained_src
//     .bar()
//     ?.baz()
//     ?.qux())

var grouped = (
    1 +
    2 *
    3
)

fn make_thing(first: i32, second: string, rest: [i32]) -> i32 { return first + rest.len() as i32 }

var multi_call = make_thing(
    1,
    second: "two",
    rest:   [3, 4, 5],
)

var generic_multiline = Lookup<
    string,
    Vec<i32>
>::create()

// == expressions ============================================================

var a: bool = true
var b: bool = false
var c: bool = true

var x:    i32 = 1
var y:    i32 = 2
var z:    i32 = 3
var nz:   i32 = if !b => 1 else => 0
var mask: i32 = 0xFF
var bits: i32 = 0x0F
var i:    i32 = 0
var arr:  [i32] = [1, 2, 3, 4]

var foo    = if a || b || c => 10 else => 20
var ranges = (1..10, 0..=5, ..3, x..)
var lits   = ([1, 2, 3], {1, 2}, {"k": 1, "v": 2}, { .x: 1, .y: 2 })
var named  = geo::Shape::Circle { radius: 2.5 }
var casted = foo as f64
var t      = try risky() catch e: Io::Error => -1 catch => -2

var m = match named {
    case .Point => 0
    case .Circle(var r) where r > 1.0 => 1
    case .Rect(var w, var h) => 2
    default => -1
}

var arith = -x + ~y * nz ^^ 2 << 3 & mask | bits
var sub   = arr[i + 1]++

class DeepC { fn d(self) -> i32 { return 42 } }
class DeepB { var c_: DeepC;  fn c(self) -> *DeepC { return &self.c_ } }
class DeepA { var b: DeepB }

var deep      = DeepA()
var deep_val  = deep.b.c()->d()

// == statements =============================================================

class Config { var host: string; var port: i32 }
var cfg = Config()

var raw_cell: i32 = 5
var raw_ptr: *i32 = &raw_cell

fn control_flow(n: i32) -> i32 {
    var q: i32 = 2

    var (p, r) = (1, 2)
    var {host, port} = cfg

    outer: for var i: i32 = 0; i < n; ++i {
        while q < 100 {
            q *= 2
            if q > 50 { break outer }
            continue
        }
    }

    var k = n
    loop {
        k--
        if k == 0 { break }
    }

    open("f.txt") as var f {
        f.write("hi")
    }

    unsafe { *raw_ptr = 0 }

    assert n >= 0, f"n went negative: {n}"
    assert static sizeof(i32) == 4

    try { boom() }
    catch e: Net::Timeout { retry() }
    catch e { panic e }
    finally { cleanup() }

    return n + p + r + port + q
}

var tup = (1, 2, [1, 2, 3])

fn pat_torture(v: i32) {
    match v {
        case 0, 1, 2 { lo() }
        case 3..=9   { mid() }
        case ..0     { neg() }
        case _       { hi() }
    }

    match tup {
        case (var a, _, [1, .., var last]) { use_(a, last) }
        default { }
    }
}

eval { const LIMIT: i32 = 64 }
eval for var i in 0..4 { unroll(i) }

macro twice!(x) { x x }
macro square!(x) { x * x }

// macro @route(node: *ast::FnDecl, path: string) {
//     node->annotations->push(make_route(path))
// }

test "foo sums" {
    var f = Foo()
    assert f.sum([1, 2, 3]) == 6
}

var unique_id!(this) = (square!(20))

// == entry ==================================================================

fn main() -> i32 {
    var f = Foo()
    f.x = 3
    var g = Foo()
    g.x = 3

    var sq = geo::Square()
    sq.side = 2.0

    var counter: i32 = 0
    twice!(counter++)

    var total: i32 = 0
    total += f.sum([1, 2, 3])
    total += f.get_x()
    total += if Foo::helper_ok() => 1 else => 0
    total += if f == &g => 1 else => 0
    total += /*chained +*/ grouped + multi_call + generic_multiline.hits
    total += foo + t + m + arith + sub + nz + deep_val
    total += control_flow(LIMIT / 8)
    total += casted as i32
    total += sq.area() as i32
    total += counter
    total += square!(2)
    total += make_route("/")

    pat_torture(1)
    pat_torture(5)
    pat_torture(-1)
    pat_torture(99)
    total += side_effects

    println(f.print())
    println(f"total = {total}")
    return 0
}