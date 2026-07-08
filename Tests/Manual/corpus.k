/// --- parser regression: foo.k -------------------------------------------
/// NOTE: no `import` / `ffi` (stubbed). no closures (TODO). everything else
/// below is implemented grammar. expected-error section at the very bottom,
/// delete it for a clean zero-error run.

// == attrs + visibility on decls ==========================================

@packed
@deprecated("use NewThing", since: 2)
pub struct OldThing {
    var a: i32
    var b: u8
}

@serializable(do_sum: true)
class Foo derives OldThing impl Printable {
    pub {
        var x: i32
        var y: i32 = 10
        fn get_x(self) -> i32 { return self.x }
    }

    priv var secret: u64

    prot {
        var shared_state: *u8
        static fn helper() -> bool = true
    }

    fn <T impl Numeric> sum(self, items: [T]) -> T {
        var total: T = 0 as T
        for var i in items {
            total += i
        }
        return total
    }

    virtual fn describe(self) -> string = virtual

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
var chained = MyFoo()
    .bar()
    ?.baz()
    ->qux()

var grouped = (
    1 +
    2 *
    3
)

var multi_call = make_thing(
    first:  1,
    second: "two",
    [3, 4, 5],
)

var generic_multiline = Lookup<
    string,
    Vec<i32>
>::create()

// == expressions ============================================================
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
var deep  = a.b->c?.d::e()

// == statements =============================================================
fn control_flow(n: i32) -> i32 {
    var (p, q) = (1, 2)
    var {host, port} = cfg

    outer: for var i: i32 = 0; i < n; ++i {
        while q < 100 {
            q *= 2
            if q > 50 { break outer }
            continue
        }
    }

    loop {
        n--
        if n == 0 { break }
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

fn pat_torture(v: i32) {
    match v {
        case 0, 1, 2 { lo() }
        case 3..=9   { mid() }
        case ..0     { neg() }
        case _       { hi() }
    }

    match tup {
        case (var a, _, [1, .., var last]) { use(a, last) }
        default { }
    }
}

eval { const LIMIT: i32 = 64 }
eval for var i in 0..4 { unroll(i) }

macro twice!(x) { x x }
macro square!(x) { x * x }

macro @route(node: *ast::FnDecl, path: string) {
    node->annotations->push(make_route(path))
}

test "foo sums" {
    var f = Foo()
    assert f.sum([1, 2, 3]) == 6
}

inline "c++" {
    ::std::puts("raw c++ body, brace { balanced }");
}

// == EXPECTED ERRORS (delete below for clean run) ===========================
pub return 1                           // err: visibility on a statement
@always_inline pub { var bad: i32 }    // err: annotation on visibility group
class Bad { pub { priv var z: i32 } }  // err: explicit vis inside group
macro @noret(n: *ast::Decl) -> i32 { } // err: attr macro return type
fn f(<i32>) {}                         // err: junk, recovery shouldn't cascade

var unique_id!(this) = (square!(20)) // should be valid