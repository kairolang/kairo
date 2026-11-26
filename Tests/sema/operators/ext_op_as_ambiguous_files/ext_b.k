import self::types::*

extend Feet {
    @implicit pub fn op as (const self) -> N { return N{v: 2} }
}
