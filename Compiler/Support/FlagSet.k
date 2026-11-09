/// --- The Kairo Project ---------------------------- Support/FlagSet.k --- ///
///
///   FlagSet: a bit set over a closed enum whose variants are single bits.
///
///   WHY: a closed enum's `x as E` is a checked conversion, so a bit mask
///   (`A | B`, a value no variant names) cannot live in the enum itself; the
///   flag enums were made `@open` for that. Here the enum names the bits and
///   stays closed, and the set is the integer the enum derives, so a
///   `FlagSet<E, u8>` field is one byte, as the open enum was. Every operation
///   is one inline bitwise op on that integer: the emitted code is the open
///   enum's.
///
///   E's variants are the bits (`A = 1 << 0`, ...); there is no `None` variant,
///   the empty set is `FlagSet<E, U>()`. U is E's underlying type, and E says
///   how a variant becomes it by implementing FlagBit<U> (a generic `E as U`
///   has no bound to check against, R051E):
///
///       extend Expr::ExprFlags impl FlagBit<u8> {
///           inline fn bit(const self) -> u8 { return self as u8 }
///       }
///
///   USAGE
///   -----
///       var f = FlagSet<Expr::ExprFlags, u8>()
///       f.set(Expr::ExprFlags::IsDependent)
///       if f.has(Expr::ExprFlags::IsDependent) { ... }
///       f.add_all(other)                        // union
///
/// ------------------------------------------------------------------------ ///

/// A flag enum's variant as its underlying integer.
pub interface <U> FlagBit {
    fn bit(const self) -> U
}

// TODO(DUCK-GENERIC): U uses `& | ~ ==` (4). A bound needs an integer
// interface over the primitive carriers; `: type` until there is one.
pub class <E impl FlagBit<U>, U: type> FlagSet {
    pub var bits: U = 0

    pub fn FlagSet(self) = default

    /// The set of one flag. A set of several is this plus `plus` / `set`:
    /// `A | B` on the closed enum is no value of it.
    pub fn FlagSet(self, f: E) {
        self.bits = f.bit()
    }

    /// \p f is in the set.
    pub inline fn has(const self, f: E) -> bool {
        return (self.bits & f.bit()) != 0
    }

    /// Any of \p o's flags is in the set.
    pub inline fn has_any(const self, o: Self) -> bool {
        return (self.bits & o.bits) != 0
    }

    /// Every one of \p o's flags is in the set (the empty set is in any).
    pub inline fn has_all(const self, o: Self) -> bool {
        return (self.bits & o.bits) == o.bits
    }

    pub inline fn empty(const self) -> bool {
        return self.bits == 0
    }

    /// The same flags: what `==` on the open enum's value was.
    pub inline fn equals(const self, o: Self) -> bool {
        return self.bits == o.bits
    }

    /// This set with \p f added, by value: builds a set in an argument
    /// (`FlagSet<E, u8>(E::A).plus(E::B)`, what `A | B` was).
    pub inline fn plus(const self, f: E) -> Self {
        var r = FlagSet<E, U>()
        r.bits = self.bits | f.bit()
        return r
    }

    pub inline fn set(self, f: E) {
        self.bits = self.bits | f.bit()
    }

    pub inline fn clear(self, f: E) {
        self.bits = self.bits & ~f.bit()
    }

    /// The union, in place.
    pub inline fn add_all(self, o: Self) {
        self.bits = self.bits | o.bits
    }

    /// The difference, in place: \p o's flags cleared.
    pub inline fn clear_all(self, o: Self) {
        self.bits = self.bits & ~o.bits
    }
}
