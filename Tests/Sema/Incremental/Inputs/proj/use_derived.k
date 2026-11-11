import derived::*

pub fn use_derived(d: *Derived) -> i32 {
    return d->hello()
}
