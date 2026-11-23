import {{ident}}::calc
import std::io

fn main() {
    for expr in ["3 4 + 2 *", "1 2 3", "2 x +"] {
        const shown = try f"{calc::evaluate(expr)}" catch e: calc::CalcError => f"error: {e.why}"
        io::println(f"{expr}  =>  {shown}")
    }
}
