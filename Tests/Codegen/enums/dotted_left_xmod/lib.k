// The enums main.k compares against with `.V` on the left: declared in
// another file, so the variant is found through the imported enum's own
// table, and a generic one at the importer's arguments.

pub enum Color derives u8 { Red, Green, Blue }

pub enum <T> Maybe { Nothing, Just { v: T } }

pub fn favourite() -> Color { return Color::Green; }

pub fn <T> wrap(x: T) -> Maybe<T> { return Maybe<T>::Just { v: x }; }
