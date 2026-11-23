pub struct CalcError { pub var why: string }

pub fn evaluate(const expr: string) panic(CalcError) -> f64 {
    var stack: [f64]
    for tok in expr.split(" ") {
        var n? = tok.parse<f64>()
        if !n? && stack.size() >= 2 {
            const b = unwrap!(stack.pop())
            const a = unwrap!(stack.pop())
            n = match tok {
                case "+" => a + b
                case "-" => a - b
                case "*" => a * b
                case "/" => a / b
                default => null
            }
        }

        if n? {
            stack.push(n)
        } else {
            panic CalcError { why: f"unexpected '{tok}'" }
        }
    }

    if stack.size() != 1 {
        panic CalcError { why: "an operator is missing" }
    }

    return stack[0]
}
