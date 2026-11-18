import lib::*

fn by_bool() -> i32 {
    var s = Slot()
    var t = Task()
    if s.push(&t) {
        return t.n
    }

    return t.n
}

fn by_null() -> i32 {
    var s = Slot()
    var t = Task()
    if s.put(&t) == null {
        return t.n
    }

    return t.n
}

fn by_panic() -> i32 {
    var s = Slot()
    var t = Task()
    try {
        s.spill(&t)
    } catch {
        return t.n
    }

    return t.n
}
