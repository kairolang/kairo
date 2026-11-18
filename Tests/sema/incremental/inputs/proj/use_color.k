import color::*

pub fn use_color(c: Color) -> i32 {
    match c {
        case Color::Red { return 1 }
        case Color::Green { return 2 }
        default { return 3 }
    }
}
