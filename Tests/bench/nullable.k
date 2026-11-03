// A singly linked list of N nodes with nullable next links: built once,
// then walked and searched 50 times.
import std::io::println
ffi "c++" import "bench_env.h"

class Node {
    var val: i64
    var next: *Node?
    fn Node(self, v: i64, n: *Node?) { self.val = v; self.next = n }
    @move fn Node(self, other: Self) = default
}

fn sum_list(head: *Node?) -> i64 {
    var s: i64 = 0
    var cur? = head
    while cur? {
        s += cur->val
        cur = cur->next
    }
    return s
}

fn find(head: *Node?, want: i64) -> *Node? {
    var cur? = head
    while cur? {
        if cur->val == want { return cur }
        cur = cur->next
    }
    return null
}

fn main() -> i32 {
    var n: i64 = bench_n()
    var head: *Node? = null
    for var i: i64 = 0; i < n; i += 1 { head = @create<Node>((i * 2654435761) % 1000003, head) }
    var total: i64 = 0
    var hits: i64 = 0
    for var r: i64 = 0; r < 50; r += 1 {
        total += sum_list(head)
        var f? = find(head, (r * 7919) % 1000003)
        if f? { hits += 1 }
    }
    var cur? = head
    while cur? {
        var next? = cur->next
        @destroy(cur)
        cur = next
    }
    println(f"{total} {hits}")
    return 0
}
