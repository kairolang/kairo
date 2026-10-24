// build: kairo F18-discarded-fstring-no-unused-result-warning.k -o f30   (expect a Kairo warning at each discarded value; gets one leaked clang C1119W plus a raw "1 warning generated.")
fn g() -> i32 { return 1 }

fn main() -> i32 {
    var x: i32 = 3
    f"x = {x}"      // builds a heap string and drops it
    x + 1           // no effect
    "lit"           // no effect
    g()             // result discarded
    return 0
}
