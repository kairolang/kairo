macro holders!(A_, B_) {
    pub class <T> A_ {
        pub var v: T

        pub fn A_(self, v: T) {
            self.v = v
        }

        pub fn get(self) -> T {
            return self.v
        }

        pub fn <U> pick(self, u: U) -> U {
            return u
        }
    }

    pub class <T> B_ {
        pub var v: T

        pub fn B_(self, v: T) {
            self.v = v
        }

        pub fn get(self) -> T {
            return self.v
        }

        pub fn <U> pick(self, u: U) -> U {
            return u
        }
    }
}

holders!(Box, Cell)
