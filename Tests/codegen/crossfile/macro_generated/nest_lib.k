macro one!(N_) {
    pub fn <T> N_(x: T) -> T {
        return x
    }
}

// The outer invocation is the position of everything the inner ones make.
macro both!(A_, B_) {
    one!(A_)
    one!(B_)
}

both!(left, right)
