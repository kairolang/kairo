// Imported by cross_module.k; not a test of its own (lit.local.cfg).
ffi "c++" import "vector"

pub enum Level derives u8 { Low, High }
pub enum <T> Slot { Full { v: T }, Hole }

pub class Item {
    pub var w: i32
    fn Item(self, w: i32) { self.w = w }
}

pub fn heavy(v: cxx::std::vector<Level>) -> i32 {
    var n = 0
    for l in v { if l == Level::High { n += 1 } }
    return n
}

pub fn filled(v: cxx::std::vector<Slot<i32>>) -> i32 {
    var n = 0
    for s in v {
        n += match s {
            case .Full(var v) => v
            default => 0
        }
    }
    return n
}

pub fn weigh(v: cxx::std::vector<*Item?>) -> i32 {
    var n = 0
    for p in v { if p? { n += p->w } }
    return n
}

pub fn holes(n: i32) -> cxx::std::vector<i32?> {
    var v: cxx::std::vector<i32?>
    for var i = 0; i < n; ++i { v.push_back(null) }
    v.push_back(n)
    return v
}
