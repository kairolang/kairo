import pt::P
pub import same
extend P impl same::Same {
    pub fn op ==(const self, other: P) -> bool = self.v == other.v
    pub fn op -(const self) -> P = P { v: 0 - self.v }
}
