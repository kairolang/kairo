// Operator declarations in an imported macro's body: the `r` marker is an
// identifier interned in THIS file's table, and the importing file must
// still read it as the postfix marker.
pub macro counting!() {
    fn op r++ (self) -> i32 { var o = self.v; self.v += 1; return o }
    fn op l++ (self) -> i32 { self.v += 100; return self.v }
    fn op + (const self, o: Self) -> i32 { return self.v + o.v }
    fn op - (const self, o: Self) -> i32 { return self.v - o.v }
}
