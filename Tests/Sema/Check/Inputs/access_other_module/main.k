import acc::Acc

fn main() -> i32 {
    var a = Acc()
    var s = a.secret
    var h = Acc::hidden
    var p = a.peek()
    var b = Acc(9)
    return s + h + p
}

// Corpus for Sema/Check/access_private.k (its checks name lines 5-8 of
// this file; keep this comment below the code).
