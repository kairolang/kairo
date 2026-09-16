import vec

pub class Font {
    pub var size: i32;
}

pub class Label {
    pub var pos:  vec::Vec2;
    pub var font: *Font;
}
