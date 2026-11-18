// Three generic functions from one macro invocation. Every token of the
// expansion is at the invocation, so the three declarations share one
// source position.
macro trio!(A_, B_, C_) {
    pub fn <T> A_(x: T) -> T {
        return x
    }

    pub fn <T> B_(x: T) -> T {
        var y = x
        return y
    }

    pub fn <T> C_(x: T, y: T) -> T {
        return y
    }
}

trio!(first, second, third)
