// OPT002R is not reported for a panic set first formed in a builtin library
// file: `F256::try_from_str` returns `Panic<F256, ParseError>` and
// `F512::try_from_str` `Panic<F512, ParseError>`, both through memory, and
// whoever reads the remark cannot change those types. A builtin generic met
// at this file's own wide type (`try_parse<Wide>`) forms its set at this
// file's call, and is reported there, as is any set the program forms
// itself (register_cliff.k).

fn names(a: f256, b: f512) -> bool = a.is_nan() || b.is_nan() // brings F256 / F512 in

struct Wide {
    var a: u64
    var b: u64
    var c: u64
    var d: u64
}

extend Wide impl FromStr {
    static fn from_str(const s: string) -> Wide? = Wide { a: s.size() as u64, b: 0, c: 0, d: 0 }
    static fn from_str_reason(const s: string, @inout err: ParseError) -> Wide? = Wide { a: 1, b: 0, c: 0, d: 0 }
}

fn wide(const s: string) -> bool {
    var v = try F256::try_from_str(s) catch e: ParseError => F256()
    return v.is_nan()
}

fn wider(const t: string) -> bool {
    try {
        var v = t.try_parse<F512>()
        return true
    } catch e: ParseError {
        return false
    }
}

fn own(const t: string) -> u64 {
    try {
        var w = t.try_parse<Wide>()
        return w.a
    } catch e: ParseError {
        return 0
    }
}

fn main() -> i32 {
    return if wide("1.5") || !wider("2") || own("x") != 1 => 1 else => 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: { %kairo %s -c -o %t.o --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --implicit-check-not="OPT002R"
// CHECK: register_cliff_builtin.k:{{[0-9]+}}:{{[0-9]+}}: remark [OPT002R]: 'Panic<Wide, ParseError>' is 40 bytes
