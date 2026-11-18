pub interface Graph {
    type Node
    fn first(const self) -> Self::Node
    fn weight(const self, n: Self::Node) -> i32
}
pub fn <G impl Graph> heaviest(g: G) -> i32 {
    var n: G::Node = g.first()
    return g.weight(n)
}
pub fn <G impl Graph> pick(g: G) -> G::Node { return g.first() }
