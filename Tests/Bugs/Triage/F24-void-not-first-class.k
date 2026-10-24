// build: kairo F24-void-not-first-class.k   (expect exit 0: void is a unit type, size 0, align 1)
fn main() -> i32 {
    if sizeof void != 0 { return 1 }
    if alignof void != 1 { return 2 }
    var u: void
    return 0
}
