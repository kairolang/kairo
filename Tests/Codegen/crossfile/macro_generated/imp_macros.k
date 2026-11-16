pub macro pair!(A_, B_) {
    pub fn <T> A_(x: T) -> T {
        return x
    }

    pub fn <T> B_(x: T) -> T {
        var y = x
        return y
    }
}
