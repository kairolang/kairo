import shapes::*

pub fn use_counter(c: *Counter) -> i32 {
    return c->get()
}
