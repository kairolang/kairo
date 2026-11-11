// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=PLAIN --allow-empty
// RUN: { %kairo %s --syntax-only --preserve-comments 2>&1 || true; } | %FileCheck %s --check-prefix=KEEP --allow-empty
// A comment never changes how code parses. With and without
// --preserve-comments, none of these shapes may produce a diagnostic.
// PLAIN-NOT: error
// KEEP-NOT: error
class P {
    pub var n: i32
    pub fn get(self) -> i32 { return self.n }
}

fn else_trailing(a: bool) -> i32 {
    if a {
        return 1
    } // why the else
    // second comment line
    else {
        return 2
    }
}

fn else_own_line(a: bool) -> i32 {
    if a {
        return 1
    }
    // comment between } and else
    else {
        return 2
    }
}

fn else_if(a: bool, b: bool) -> i32 {
    if a {
        return 1
    }
    // comment before else if
    else if b {
        return 2
    }
    else {
        return 3
    }
}

fn leading_or(a: bool, b: bool) -> bool {
    return a
        // why the second operand
        || b
}

fn leading_and(a: bool, b: bool) -> bool {
    return a
        // note
        && b
}

fn leading_dot(p: P) -> i32 {
    return p
        // call it
        .get()
}

fn leading_arrow(p: *P) -> i32 {
    return p
        // call it through the pointer
        ->get()
}

fn leading_or_cond(a: bool, b: bool) -> i32 {
    if a
        // continued condition
        || b {
        return 1
    }
    return 0
}
