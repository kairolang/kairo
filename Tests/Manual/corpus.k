/// --- parser regression: corpus.k ----------------------------------------
/// Clean-run corpus: parses AND name-resolves with zero diagnostics.
/// No import/ffi (stubbed). No closures (TODO).
///
/// KNOWN COMPILER BUG (not a corpus issue): members declared inside a
/// `pub { }` / `prot { }` visibility group are resolved twice and report
/// [R001E] '<name>' redefined against themselves. Members are declared with
/// per-member visibility below to route around it. Restore the grouped form
/// once the resolver stops double-walking group bodies.

// == stubs so every identifier below resolves ==============================

interface Printable {
    fn print(self) -> string
}

interface Numeric {
    fn zero() -> i32
}

class Pair { var l: i32; var r: i32 }
class Vec  { var n: i32 }
class Map  { var n: i32 }

module Io    { class Error  { var code: i32 } }
module Net   { class Timeout { var ms: i32 } }
module ast   { class FnDecl  { var id: i32 }
               class Decl    { var id: i32 } }

fn risky() -> i32
fn boom() -> i32
fn retry() -> i32
fn cleanup()
fn lo()
fn mid()
fn neg()
fn hi()
fn unroll(i32)
fn use_(i32, i32)
fn make_route(string) -> i32

// == attrs + visibility on decls ==========================================

@packed
@deprecated("use NewThing", since: 2)
pub struct OldThing {
    var a: i32
    var b: u8
}

@serializable(do_sum: true)
class Foo derives OldThing impl Printable {
    pub var x: i32
    pub var y: i32 = 10
    pub fn get_x(self) -> i32 { return self.x }

    priv var secret: u64

    prot var shared_state: *u8
    prot static fn helper() -> bool { return true }

    fn <T impl Numeric> sum(self, items: [T]) -> T {
        var total: T = 0 as T
        for var i in items {
            total += i
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
}

// == newline rules =========================================================

class MyFoo {
    fn bar(self) -> *MyFoo { return &self }
    fn baz(self) -> *MyFoo { return &self }
    fn qux(self) -> i32    { return 0 }
}

var chained = MyFoo()
    .bar()
    ?.baz()
    ->qux()

var grouped = (
    1 +
    2 *
    3
)

fn make_thing(first: i32, second: string, rest: [i32]) -> i32 { return first }

// var multi_call = make_thing(
//     first:  1,
//     second: "two",
//     [3, 4, 5],
// )

class Lookup {
    static fn create() -> i32 { return 0 }
}

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
var z:    i32 = 0
var mask: i32 = 0xFF
var bits: i32 = 0x0F
var i:    i32 = 0
var arr:  [i32] = [1, 2, 3, 4]

var foo    = if a || b || c { 10 } else { 20 }
var ranges = (1..10, 0..=5, ..3, x..)
var lits   = ([1, 2, 3], {1, 2}, {"k": 1, "v": 2}, { .x: 1, .y: 2 })
var named  = geo::Shape::Circle { radius: 2.5 }
var casted = foo as f64
var t      = try { risky() } catch e: Io::Error { -1 } catch { -2 }

var m = match named {
    case .Point { 0 }
    case .Circle(var r) where r > 1.0 { 1 }
    case .Rect(var w, var h) { 2 }
    default { -1 }
}

var arith = -x + ~y * !z ^^ 2 << 3 & mask | bits
var sub   = arr[i + 1]++

class DeepA { var b: *DeepB }
class DeepB { fn c(self) -> *DeepC { return &null } }
class DeepC { fn d(self) -> i32 { return 0 } }

// == statements =============================================================

class Config { var host: string; var port: i32 }
var cfg = Config()

var raw_ptr: *i32 = &null

fn open(string)

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

    return n
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

inline "c++" {
    ::std::puts("raw c++ body, brace { balanced }");
}

var unique_id!(this) = (square!(20))
