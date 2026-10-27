// shapes.k: a second module with enums, so its include writes the niche
// helpers' would-be second copy.
pub enum Kind { Dot, Line, Box }

pub enum Mark { Set { k: Kind }, Clear }
