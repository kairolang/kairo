// ext_a.k  first half of a module extended across two TUs (case 9).
//   Both ext_a and ext_b expose a module named `shape`. Importing both into
//   one file yields ONE overlay key `shape` with TWO module targets (module
//   extension), NOT an ambiguity: same-named modules from different TUs merge
//   their scopes rather than clashing.

pub module shape {
    pub fn area_a() -> i32 {
        return 1
    }
}
