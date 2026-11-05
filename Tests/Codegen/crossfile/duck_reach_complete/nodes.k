// Imported by app.k through user.k, not a test of its own.
ffi "c++" import "llvm/ADT/SmallVector.h";

pub class Table {
    pub var n: i32 = 4
    fn Table(self) {}
}
pub class Ctx {
    pub var g: unsafe *Table = &null
    fn Ctx(self) {}
}
pub class Typer {
    pub var sc: unsafe *Ctx = &null
    fn Typer(self) {}
}
// A `<T: type>` body: the chain through T is untyped until C++ instantiates it.
pub class <T: type> Duck {
    pub var d: unsafe *T = &null
    fn Duck(self) {}
    fn read(self) -> i32 { return self.d->sc->g->n; }
}
pub class Big {
    pub var a: i32 = 1
    fn Big(self) {}
}
// SmallVector stores its first elements inline: the tuple record must be
// defined ahead of Store, in this file's own TU. Never constructed, so the
// test needs no LLVMSupport to link.
pub class Store {
    pub var pairs: llvm::SmallVector<(unsafe *Big, i32), 4>
}
pub class Thing {
    pub var v: i32 = 5
    fn Thing(self) {}
}
