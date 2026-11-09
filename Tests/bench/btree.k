import std::io::println
ffi "c++" import "bench_env.h"

class Node {
    var left: *Node?
    var right: *Node?

    fn Node(self) { self.left = null; self.right = null }
    fn Node(self, l: *Node, r: *Node) { self.left = l; self.right = r }

    @move fn Node(self, other: Self) = default

    fn op finally(self) {
        if self.left? { @destroy(self.left) }
        if self.right? { @destroy(self.right) }
    }

    fn check(const self) -> i32 {
        if self.left? && self.right? { return 1 + self.left->check() + self.right->check() }
        return 1
    }
}

fn bottom_up(depth: i32) -> *Node {
    if depth > 0 { return @create<Node>(bottom_up(depth - 1), bottom_up(depth - 1)) }
    return @create<Node>()
}

fn main() -> i32 {
    var n = bench_n() as i32
    var max_depth = if n > 6 => n else => 6
    {
        var *stretch = bottom_up(max_depth + 1)
        println(f"stretch tree of depth {max_depth + 1}\t check: {stretch->check()}")
        @destroy(stretch)
    }
    var *long_lived = bottom_up(max_depth)
    for var d = 4; d <= max_depth; d += 2 {
        var iters = 1 << (max_depth - d + 4)
        var check = 0
        for var i = 0; i < iters; i += 1 {
            var *t = bottom_up(d)
            check += t->check()
            @destroy(t)
        }
        println(f"{iters}\t trees of depth {d}\t check: {check}")
    }
    println(f"long lived tree of depth {max_depth}\t check: {long_lived->check()}")
    @destroy(long_lived)
    return 0
}
