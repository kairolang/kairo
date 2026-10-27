// colors.k: a plain enum a niche can use, and an ADT holding a pointer.
pub enum Color derives u8 { Red, Green, Blue }

pub struct Pixel { pub var c: Color = Color::Red }

pub enum Slot { Has { p: *Pixel }, Empty }

pub fn pick(s: Slot) -> i32 = match s {
    case .Has(var p) => p->c as u8
    case .Empty      => -1
}

// Names `Color?` and `*Pixel?`, so the module's header carries Nullable.
pub fn first(c: Color?, p: *Pixel?) -> bool = c? && p?
