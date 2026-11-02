// Driven by ../duck_operators.k: a duck body's discarded operators whose
// instance is a panicking user operator, which the instance must reject.
// Each operator's result type differs: clang reports a static_assert once
// per `operator,` specialization, so two sites at one Panic type would show
// as one error.
struct Bad {}
struct Boom {
    var v: i32
    fn op + (const self, o: Boom) panic(Bad) -> Boom { panic Bad {} }
    fn op - (const self) panic(Bad) -> i32 { panic Bad {} }
    fn op *= (self, o: Boom) panic(Bad) { panic Bad {} }
}

fn <T: type> add_drop(a: T, b: T) { a + b }
fn <T: type> neg_drop(a: T) { -a }
fn <T: type> acc_drop(a: T, b: T) {
    var u = a
    u *= b
}

fn main() -> i32 {
    add_drop(Boom { v: 1 }, Boom { v: 2 })
    neg_drop(Boom { v: 1 })
    acc_drop(Boom { v: 1 }, Boom { v: 2 })
    return 0
}
