ffi "python" import sympy as sp;
ffi "c++"    import "circle.hh";

fn main() {
    var eq1: sp::Eq  = sp::Eq(x + y, 10)
    var eq2: sp::Eq  = sp::Eq(x - y, 4)
    var solutions  = sp.solve((eq1, eq2), (x, y)); // type inferd by the compiler

    print(solutions);

    var circle = circle::Circle{10, 20};

    print(circle->to_string());
}