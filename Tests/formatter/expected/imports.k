// RUN: %kfmt --stdout %s | diff -u %S/expected/imports.k -
// RUN: %kfmt --check %S/expected/imports.k
//
// Section 5: ffi imports first in their own order, one blank line, then
// the Kairo imports sorted by path. One name loses its braces (5.1), two to
// more go one per line, never a grid (5.2), and a
// comment directly above an import travels with it (5.4).

ffi "c++" import "zlib.h"
ffi "c++" import "assert.h"

import alpha::beta
import alpha::beta::Delta as D
pub import api::{
    One,
    Two,
}
// the widgets, sorted inside the braces too
import kit::{
    Axle,
    Frame,
    Wheel,
}
import kit::parts::*
import kit::parts::nested::Bolt
import self::local::thing // trailing comment stays with its import
import many::{
    Alpha,
    Beta,
    Delta,
    Epsilon,
    Eta,
    Gamma,
    Theta,
    Zeta,
}
import zeta::Gamma

fn main() -> i32 {
    return 0
}
