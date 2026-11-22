import shape::Shape
import point::Point
import point_name
import dot::Dot
import dot_name
import dot_shape

fn <S impl Shape> measure(s: S) -> i32 {
    return s.area() + s.name()
}

fn main() -> i32 {
    return measure(Point()) + measure(Dot())
}

// Corpus for sema/check/impl_declared_other_file.k.
