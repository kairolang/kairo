priv fn base() -> i32 { return 40 }

// A default that calls a function private to this file: its thunk's body
// is in this file's object, the one TU that can name base().
pub class Counter {
    pub var n: i32 = base() + 2
}

// A generic record's default: its thunk is a template body, compiled by
// every TU that builds an instance.
pub class <T> Holder {
    pub var v: T = T()
    pub var tag: i32 = 7
}
