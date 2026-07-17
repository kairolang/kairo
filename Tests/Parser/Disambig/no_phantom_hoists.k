// Bug 2 regression: a statement-position binding (for-header) must not be
// hoisted into the DisambigTable. Observable in the AST: if `phantom` had
// been hoisted as generic (old indexer + old sentinel), `phantom < 3`
// after the loop would misparse as generic args.

fn main() -> i32 {
    var a = 0
    
    for var phantom: i32 = 0; phantom < 10; ++phantom {
        a = a + 1
    }

    var z = a < 3
    return 0
}
