/// --- The Kairo Project ----------------------------- Tests/Imports/bar.k --- ///
///
///   Source module for the cross-TU generic-disambiguation corpus (Phase I,
///   Step 2). Defines one generic FUNCTION and one generic TYPE. Importers in
///   this directory pull `bar` in four ways (plain / selective / aliased /
///   wildcard) and use `id` and `Box` in BARE generic position (`id<i32>(1)`,
///   `Box<i32>`), which before the import-edge fallback misparsed the `<` as a
///   comparison operator.
///
/// --------------------------------------------------------------------------- ///

/// generic function: bare `id<i32>(1)` is the ambiguous head-position case.
pub fn <T> id(x: T) -> T {
    return x;
}

/// generic type: bare `Box<i32>` is the ambiguous type/value case.
pub class <T> Box {
    pub var value: T;

    pub fn Box(self, v: T) {
        self.value = v;
    }
}

/// a NON-generic name, to prove the fallback does not over-fire:
/// `limit < 3` must still parse as a comparison, not generic args.
pub var limit: i32 = 10;
