// Both partials match Pair<i32, i32> and neither is more specialized.
pub struct <A, B> Pair { pub var a: A; pub var b: B }
pub struct <X> Pair<X, i32> { pub var left: X }
pub struct <Y> Pair<i32, Y> { pub var right: Y }
