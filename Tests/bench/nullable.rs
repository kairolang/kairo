// See nullable.k. Option<Box<Node>>.
struct Node { val: i64, next: Option<Box<Node>> }

fn sum_list(mut n: Option<&Node>) -> i64 { let mut s = 0; while let Some(x) = n { s += x.val; n = x.next.as_deref(); } s }
fn find(mut n: Option<&Node>, want: i64) -> Option<&Node> { while let Some(x) = n { if x.val == want { return Some(x); } n = x.next.as_deref(); } None }

fn main() {
    let n: i64 = std::env::var("N").unwrap().parse().unwrap();
    let mut head: Option<Box<Node>> = None;
    for i in 0..n { head = Some(Box::new(Node { val: (i * 2654435761) % 1000003, next: head })); }
    let (mut total, mut hits) = (0i64, 0i64);
    for r in 0..50 {
        total += sum_list(head.as_deref());
        if find(head.as_deref(), (r * 7919) % 1000003).is_some() { hits += 1; }
    }
    let mut cur = head.take();
    while let Some(mut b) = cur { cur = b.next.take(); }   // iterative teardown
    println!("{} {}", total, hits);
}
