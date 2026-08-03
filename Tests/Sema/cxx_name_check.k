fn template() -> i32 { return 0 }

class typedef {
    var signed: i32;
    var noexcept: i32;
}

fn ok_name(explicit: i32, __evil: i32, _Bad: i32, _lead: i32) -> i32 {
    var friend: i32 = 1;
    var fine__here: i32 = 2;
    return explicit
}

enum Colors {
    Red,
    __protected,
}

type wchar_t = i32;

module namespace { }

fn clean(a: i32, b: i32) -> i32 { return a }
