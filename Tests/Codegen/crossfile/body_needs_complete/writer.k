// Imported by app.k, not a test of its own. Every body here names nodes.k's
// classes only through pointers or template arguments, yet C++ needs each
// one complete in THIS TU.
import nodes::*

// `return n` is a static_cast<Base *>: Sub complete to relate the two.
pub fn up(n: unsafe *Sub) -> unsafe *Base {
    return n;
}
// k is Base's, looked up in Sub: Sub complete.
pub fn inherited(n: unsafe *Sub) -> i32 {
    return n->k;
}
// Holder's implicit destructor runs ~vector<Elem>: Elem complete.
pub fn drop_holder() -> i32 {
    var h = Holder()
    return 0;
}
// probe<Tagged> is instantiated here and calls Tagged::tag(): Tagged complete.
pub fn tagged(n: unsafe *Base) -> i32 {
    return probe<Tagged>(n);
}
