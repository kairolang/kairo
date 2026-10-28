// Imported by use.k (EVAL.md §11): a record whose field types C++ computes
// from eval fns, and the header that carries it.
pub eval fn twice(x: usize) -> usize { return x * 2 }

pub class Table {
    pub var rows: [i32; twice(2)]
    fn Table(self) { }
    fn last(const self) -> i32 { return self.rows[twice(2) - 1] }
}
