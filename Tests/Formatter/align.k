// RUN: %kfmt --stdout %s | diff -u %S/Expected/align.k -
// RUN: %kfmt --check %S/Expected/align.k
//
// Section 11: consecutive assignments align `=` (11.1); consecutive
// declarations align keyword, name, type and `=` columns, `:` glued to the
// name (11.2); enum values align `=` (7.4); trailing comments in a run line
// up one space past the longest line (11.4, proposed). A blank line ends a
// run.

enum FileMode derives u8 {
    Read = 1 << 0,
    Write = 1 << 1,
    Execute = 1 << 2,
}

class Doc {
    pub var kind: DocKind = DocKind::Concat;
    pub var txt: string = "";
    pub var children: vec<Doc>;
}

fn f() {
    var i1: u32;
    const i2: u32;
    static i3: u32;
    var itemscount: u8;

    item1 = 67;
    item2 = 34;
    itemscount = 56;
    tree = "binary";

    var t = 2;
    var long_name: i32 = 3;

    var unsafe *p = get();
    var q = other();
}

enum K {
    Text,
    Line, ///< a space flat, a newline broken
    HardLine,  ///< always a newline
}
