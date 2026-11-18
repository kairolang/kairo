// Inside a module an unmarked function is `prot`: not `priv`, so it is in
// the module's C++ header and its calling convention is SC136E.

@preserve_most
fn prot_by_default(n: usize) -> usize { return n }

class Open {
    @preserve_most
    fn method(self) -> i32 { return 1 }
}

@preserve_most
priv fn file_local(n: usize) -> usize { return n }

fn main() -> i32 {
    return file_local(0) as i32
}
