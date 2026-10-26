// Corpus for Sema/Check/access_private.k: the class, in its own module.
pub class Acc {
    var secret: i32 = 3
    static hidden: i32 = 5
    priv fn peek(const self) -> i32 { return self.secret }

    pub fn Acc(self) { }
    priv fn Acc(self, s: i32) { self.secret = s }
}
