// An ordinary program: outside every library, it sees the staged std.
import std::io

fn main() -> i32 {
    return io::staged_io()
}
