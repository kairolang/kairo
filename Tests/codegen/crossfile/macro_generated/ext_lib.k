pub class Meter {
    pub var n: i32 = 4

    pub fn Meter(self) { }
}

macro readers!(A_, B_) {
    extend Meter {
        pub fn <T> A_(const self, x: T) -> T {
            return x
        }

        pub fn <T> B_(const self, x: T) -> T {
            var y = x
            return y
        }
    }
}

readers!(plain, copied)
