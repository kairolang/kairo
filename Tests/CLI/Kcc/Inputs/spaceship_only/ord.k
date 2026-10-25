// ord.k: declares only `op <=>`; the other five comparisons and `==` are
// derived, and C++ sees them as members of Rank.
pub class Rank {
    pub var n: i32

    pub fn Rank(self, n: i32) {
        self.n = n
    }

    pub fn op <=> (const self, other: Rank) -> Ordering {
        if self.n < other.n { return Ordering::Less }
        if self.n > other.n { return Ordering::Greater }
        return Ordering::Equal
    }
}
