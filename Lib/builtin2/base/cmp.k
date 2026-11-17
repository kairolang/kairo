/// builtin/base/cmp.k

pub enum Ordering derives i8 { Less = -1, Equal = 0, Greater = 1 }

/// Builtin types satisfy Eq / Ord through their built-in operators.
pub interface Eq {
    fn op == (const self, const o: Self) -> bool
}

pub interface Ord derives Eq {
    fn op <=> (const self, const o: Self) -> Ordering
}

/// Static, not a constructor requirement: builtins can't satisfy those,
/// but an `extend` can give them a static.
pub interface Default {
    static fn make_default() -> Self
}
