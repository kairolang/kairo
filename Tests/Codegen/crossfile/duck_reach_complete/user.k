// Imported by app.k, not a test of its own. Each body needs a class of
// nodes.k complete that no typed node of it names by value.
import nodes::*
ffi "c++" import "Inputs/mk.hh";

// Duck<Typer>::read walks Typer -> Ctx -> Table.
pub fn duck_read(t: unsafe *Typer) -> i32 {
    var d = Duck<Typer>()
    d.d = t
    return d.read();
}
// mk::make<Thing> is `new Thing()`; the result is only held.
pub fn made() -> i32 {
    var p: unsafe *Thing = mk::make<Thing>()
    return 1;
}
