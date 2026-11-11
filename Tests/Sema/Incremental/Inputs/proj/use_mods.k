import mods
import mathlib as ml

pub fn use_mods() -> i32 {
    return mods::util::helper(1) + ml::add(1, 2)
}
