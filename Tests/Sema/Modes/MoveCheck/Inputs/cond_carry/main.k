import lib::*

fn forwarded_bool() -> i32 {
    var s = Slot()
    var t = Task()
    if !try_push(&s, &t) {
        return t.n
    }

    return t.n
}

fn forwarded_null() -> i32 {
    var s = Slot()
    var t = Task()
    if find(&s, &t) != null {
        return t.n
    }

    return t.n
}

fn stored_bool() -> i32 {
    var s  = Slot()
    var t  = Task()
    var ok = s.push(&t)
    if ok {
        return t.n
    }

    return t.n
}

fn stored_null() -> i32 {
    var s  = Slot()
    var t  = Task()
    var r? = s.put(&t)
    if r == null {
        return t.n
    }

    return t.n
}

fn by_panic_type() -> i32 {
    var t = Task()
    try {
        spill(&t, 1)
    } catch e: Other {
        return t.n
    } catch e: Full {
        return t.n
    }

    return t.n
}
