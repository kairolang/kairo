// kcc_adt_factory_clash.k's module: variants whose names are already taken
// in the C++ record their factories go into.

// `Shape` is the record's own name -- its constructors' -- so its factory
// is `Shape_`. `is_null` is taken only in the Nullable record, not here,
// and keeps its name. A field named like the record only moves its
// parameter aside.
pub enum Shape {
    Shape  { w: i32 },
    is_null,
    Pt     { Shape: i32 },
}

// The `_` repeats while taken: the variant literally named `Node_` claims
// its own name first, so the clashing `Node` becomes `Node__`.
pub enum Node {
    Node  { v: i32 },
    Node_ { v: i32 },
}

pub fn shape_code(s: Shape) -> i32 = match s {
    case .Shape(var w)   => w
    case .is_null        => -1
    case .Pt(var Shape)  => 100 + Shape
}

pub fn node_code(n: Node) -> i32 = match n {
    case .Node(var v)  => v
    case .Node_(var v) => 10 * v
}
