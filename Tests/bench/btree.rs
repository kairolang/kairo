struct Node { children: Option<(Box<Node>, Box<Node>)> }

impl Node {
    fn bottom_up(depth: u32) -> Box<Node> {
        let children = if depth > 0 { Some((Node::bottom_up(depth - 1), Node::bottom_up(depth - 1))) } else { None };
        Box::new(Node { children })
    }
    fn check(&self) -> i32 {
        match &self.children { Some((l, r)) => 1 + l.check() + r.check(), None => 1 }
    }
}

fn main() {
    let n: u32 = std::env::var("N").unwrap().parse().unwrap();
    let max_depth = n.max(6);
    {
        let stretch = Node::bottom_up(max_depth + 1);
        println!("stretch tree of depth {}\t check: {}", max_depth + 1, stretch.check());
    }
    let long_lived = Node::bottom_up(max_depth);
    for d in (4..=max_depth).step_by(2) {
        let iters = 1 << (max_depth - d + 4);
        let check: i32 = (0..iters).map(|_| Node::bottom_up(d).check()).sum();
        println!("{}\t trees of depth {}\t check: {}", iters, d, check);
    }
    println!("long lived tree of depth {}\t check: {}", max_depth, long_lived.check());
}
