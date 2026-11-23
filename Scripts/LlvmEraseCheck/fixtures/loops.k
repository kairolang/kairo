// The checker's own fixture: every HIT and PASS it must report, and the
// loops it must leave alone. Each expected line is named in the comment on
// the line it points at. Run:
//   erase_check Scripts/LlvmEraseCheck/fixtures/loops.k <the LLVM --cxx-include roots>

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/ADT/StringMap.h"

fn drop_key(@inout m: llvm::DenseMap<u32, u32>, k: u32) {
    m.erase(k)
}

fn read_key(m: *llvm::DenseMap<u32, u32>, k: u32) -> bool {
    return m->count(k) != 0
}

class Holder {
    pub var map:   llvm::DenseMap<u32, u32>
    pub var other: llvm::DenseMap<u32, u32>

    fn Holder(self) = default

    fn forget(self, k: u32) {
        self.map.erase(k)
    }

    fn forget_other(self, k: u32) {
        self.other.erase(k)
    }

    fn sweep(self) {
        for *e in self.map {
            if e->second == 0 {
                self.forget(e->first) // HIT: forget, through self
            }

            self.forget_other(e->first) // not a hit: another field
        }
    }

    fn sweep_direct(self) {
        for *e in self.map {
            self.map.erase(e->first) // HIT: direct, on a field
        }
    }
}

pub fn main() -> i32 {
    var m: llvm::DenseMap<u32, u32>
    var n: llvm::DenseMap<u32, u32>
    m.try_emplace(1, 2)

    for *e in m {
        if e->second == 2 {
            m.erase(e->first) // HIT: direct
        }

        n.erase(e->first) // not a hit: another map
    }

    for *e in m {
        drop_key(&m, e->first) // HIT: helper, through a parameter
        read_key(&m, e->first) // not a hit: the helper does not erase
    }

    var s: llvm::StringMap<bool>
    for var it = s.begin(); it != s.end(); ++it {
        s.erase(it) // HIT: indexed for holding an iterator
    }

    var it2 = s.begin()
    while it2 != s.end() {
        s.remove(unsafe &*it2) // HIT: while holding an iterator
        ++it2
    }

    var d: llvm::DenseSet<u32>
    for *k in d {
        d.erase(*k) // HIT: DenseSet
    }

    var keep: [u32]
    for *e in m {
        keep.push(e->first) // not a hit: collect, then erase after the loop
    }

    for *k in keep {
        m.erase(*k)
    }

    return 0
}
