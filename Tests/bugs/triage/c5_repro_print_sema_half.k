// build: kairo Z2-c5-print-sema-variant.k --print-sema --type-check-only
// C5's second command line (the --print-sema half of the same claim).
fn outer() {
    class Inner {
        var v: i32
        fn get(self) -> i32 { return self.v }
    }
}
