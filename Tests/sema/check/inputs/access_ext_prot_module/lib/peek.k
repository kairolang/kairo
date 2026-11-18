import self::der::Inner
pub interface Peek { fn peek(self) -> i32 }
extend Inner impl Peek {
    fn peek(self) -> i32 { return self.ctx + self.tag + self.bump() }
}
