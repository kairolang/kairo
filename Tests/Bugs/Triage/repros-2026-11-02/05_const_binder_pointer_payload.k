// A `const` match binder on a pointer payload.
// Expected: `const l` makes the binding const (Expr* const); passing it to a
// function taking *Expr is fine. Exit 5.
// Actual: CL001E "cannot initialize a parameter of type 'Expr *' with an
// lvalue of type 'const Expr *'" -- the const lands on the pointee. `var l`
// works.
enum Expr {
    Num { v: i64 },
    Add { l: *Expr, r: *Expr },
}

fn value(e: *Expr) -> i64 = match *e {
    case .Num(const v) => v
    case .Add(const l, const r) => value(l) + value(r)
}

fn main() -> i32 {
    var *a = @create<Expr>(Expr::Num { v: 2 })
    var *b = @create<Expr>(Expr::Num { v: 3 })
    var *s = @create<Expr>(Expr::Add { l: a, r: b })
    return value(s) as i32   // exit 5
}
