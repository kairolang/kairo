pub fn _pub_fn() -> i32 {
    return 1
}

fn _plain_fn() -> i32 {
    return 2
}

prot fn _prot_fn() -> i32 {
    return 3
}

priv fn _priv_fn() -> i32 {
    return 4
}

class Box {
    priv var _hidden: i32 = 0
    pub var _shown:   i32 = 0
}

fn local_names(_p: i32) -> i32 {
    var _l = _p
    return _l
}
