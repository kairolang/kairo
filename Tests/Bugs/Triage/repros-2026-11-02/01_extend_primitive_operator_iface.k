// extend on a primitive that conforms it to an interface with an operator
// requirement. Expected: compiles; i64 satisfies Less, smallest() returns 2.
// Actual: CL001E "overloaded 'operator<' must have at least one parameter of
// class or enumeration type" -- the requirement is emitted as a real C++
// operator< on long instead of through Less's witness.
pub interface Less { fn op < (const self, const o: Self) -> bool }

extend i64 impl Less {
    fn op < (const self, const o: i64) -> bool { return (self as i64) < (o as i64) }
}

fn <T impl Less> smaller(a: T, b: T) -> T { return if a < b => a else => b }

fn main() -> i32 { return smaller<i64>(5, 2) as i32 }   // exit 2
