// shapes.k: a second module with enums, so its include writes the niche
// helpers' would-be second copy.
pub enum Kind { Dot, Line, Box }

pub enum Mark { Set { k: Kind }, Clear }

pub enum Pin { At { k: *Kind }, Loose }

// `@open`: Bits may hold any u8, so it has no niche and Wrap keeps a tag.
@open pub enum Bits derives u8 { Lo, Hi }

pub enum Wrap { Set { b: Bits }, Clear }
