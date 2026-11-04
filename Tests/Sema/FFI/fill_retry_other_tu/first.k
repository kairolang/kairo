// Corpus for main.k: checked ahead of it, its set imports <memory> but not
// thing.h, and it reads a member of maker.k's unique_ptr<Thing>.
ffi "c++" import "memory"
import maker::*

pub fn peek() -> bool { var raw = hold(&null)->release(); return true }
