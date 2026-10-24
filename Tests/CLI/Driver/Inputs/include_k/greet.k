import std::io::println

pub fn greet(n: i32) -> i32 {
    var s: string = "hi";
    println(f"greet {s} {n}");
    return n + 1;
}
