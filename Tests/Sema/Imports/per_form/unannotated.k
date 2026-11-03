// unannotated.k  source module for main_unannotated.k.
//   fn twice, class Pair, var base   no visibility written: top-level
//                                    declarations default to `pub`
//   priv fn hidden                   private: still the R047E at a use

fn twice(x: i32) -> i32 {
    return x * 2
}

class Pair {
    var a: i32 = 0
    var b: i32 = 0

    fn Pair(self, a: i32, b: i32) {
        self.a = a
        self.b = b
    }
}

var base: i32 = 1

priv fn hidden() -> i32 {
    return 7
}
