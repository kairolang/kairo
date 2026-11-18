// Reaches for a module that only an unnamed -I dir holds: a library file
// never does, registered or not (module_walkup.k).
import helper

pub fn leak() -> i32 { return helper::help() }
