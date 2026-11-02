// Imported by main.k. Every declaration sits in a branch of a file-scope
// `eval if`: EvalIfFolding hoists the taken one in Sema, but the parse-time
// index an importer disambiguates `<` against is built long before that.

eval if true {
    pub fn <T> pick(v: T) -> T { return v }
} else {
    pub fn <T> pick(v: T) -> T { return v }
}

eval if false {
    pub fn helper() { }
}
else if false {
    pub fn helper() { }
}
else {
    pub fn <T> late(v: T) -> T { return v }
    eval if true {
        pub fn <T> deep(v: T) -> T { return v }
    }
}
