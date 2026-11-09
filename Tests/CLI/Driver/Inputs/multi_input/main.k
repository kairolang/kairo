import std::io::println
import self::foo

fn main() -> i32 {
    println(f"main {foo::f(2)}");
    return foo::f(3);
}
