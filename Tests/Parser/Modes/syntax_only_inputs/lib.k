// Imported by main.k, with no RUN line of its own. A syntax error of its
// own, which only a mode that compiles the import closure reports, and a
// generic main.k's `<` must still be disambiguated against.

pub fn <T> pick(v: T) -> T { return v }

pub fn broken() -> i32 {
    return (1 +
}
