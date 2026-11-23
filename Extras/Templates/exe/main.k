import std::io
import {{ident}}::calc::CalcError
import {{ident}}::calc::evaluate

fn main() {
    for expr in ["3 4 + 2 *", "1 2 3", "2 x +"] {
        var shown = try f"{evaluate(expr)}" catch e: CalcError => f"error: {e.op panic()}"
        io::println(f"{expr}  =>  {shown}")
    }
}
