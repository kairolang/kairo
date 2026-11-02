// Driven by ../duck_discard.k: a duck body's discarded call of a panicking
// method, which the instance must reject.
class Boom {
    fn value(const self) panic -> i32 { panic 3 }
}

fn <T: type> drop_it(t: T) { t.value() }

fn main() -> i32 {
    drop_it(Boom())
    return 0
}
