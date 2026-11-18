// Corpus for sema/types/inherited_member_type.k: no base has the name.
class Base { pub class Inner { pub var v: i32 = 0 } }
class Der derives Base { }
fn main() -> i32 {
    var bad: Der::Nope
    return 0
}
