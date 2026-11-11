// `<=>` on two primitives is the Ordering lang item (operators.mdx): C++'s
// own `<=>` answers a std::strong_ordering, which converts to no
// Ordering, so `var o = 1 <=> 2` would fail in clang. Each case is
// checked against the documented variant, through `==`, `match`, an `as i8`
// and a returned value; an operand with an effect runs once.

fn cmp(a: i64, b: i64) -> Ordering { return a <=> b }

var calls = 0

fn bump() -> i32 {
    calls += 1
    return calls
}

fn main() -> i32 {
    var o = 1 <=> 2
    if o != Ordering::Less { return 1 }
    var m = match 3 <=> 2 {
        case Ordering::Greater => 0
        default => 1
    }

    if m != 0 { return 2 }
    var big: u64 = 18446744073709551615
    if ((big <=> (0 as u64)) as i8) != 1 { return 3 }
    if ('a' <=> 'a') != Ordering::Equal { return 4 }
    if (false <=> true) != Ordering::Less { return 5 }
    if cmp(7, 7) != Ordering::Equal { return 6 }
    if (bump() <=> 5) != Ordering::Less || calls != 1 { return 7 }
    return 0
}

// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
