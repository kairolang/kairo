import self::types::*

extend Feet {
    @implicit pub fn op as (const self) -> M { return M{v: self.v * 2} }
}
