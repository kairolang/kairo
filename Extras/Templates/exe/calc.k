/// Reverse-Polish arithmetic: "3 4 + 2 *" is (3 + 4) * 2.
pub enum CalcError {
    BadToken { tok: string },
    StackUnderflow,
    Leftover,
}

extend CalcError {
    pub fn op panic (const self) -> string = match self {
        case .BadToken(const tok) => f"'{tok}' is not a number or an operator"
        case .StackUnderflow => "an operator needs two numbers before it"
        case .Leftover => "numbers are left over: an operator is missing"
    }
}

pub fn evaluate(const expr: string) panic(CalcError) -> f64 {
    var stack: [f64]
    for tok in expr.split(" ") {
        var n? = tok.parse<f64>()
        if !n? {
            if tok != "+" && tok != "-" && tok != "*" && tok != "/" {
                panic CalcError::BadToken { tok: tok }
            }

            var b? = stack.pop()
            var a? = stack.pop()
            if !a? || !b? {
                panic CalcError::StackUnderflow
            }

            n = match tok {
                case "+" => a + b
                case "-" => a - b
                case "*" => a * b
                default => a / b
            }
        }

        stack.push(n)
    }

    if stack.size() != 1 {
        panic CalcError::Leftover
    }

    return stack[0]
}
