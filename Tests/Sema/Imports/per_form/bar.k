// bar.k  source module for the import corpus.
//   pub  fn id<T>       generic function (fn-set target, union tests)
//   pub  class Box<T>   generic type    (type target, disambig tests)
//   pub  var limit      non-generic value (negative-control / wildcard fold)
//   priv fn  secret     private decl: enters a wildcard overlay WITH the priv
//                       fact carried, for the future "exists but priv" error.

pub fn <T> id(x: T) -> T {
    return x
}

pub class <T> Box {
    pub var value: T

    pub fn Box(self, v: T) {
        self.value = v
    }
}

pub var limit: i32 = 10

priv fn secret() -> i32 {
    return 42
}
