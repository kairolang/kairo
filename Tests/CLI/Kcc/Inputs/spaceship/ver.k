// ver.k
pub class Version {
    pub var major: i32
    pub var minor: i32

    pub fn Version(self, major: i32, minor: i32) {
        self.major = major
        self.minor = minor
    }

    pub fn op <=> (const self, other: Version) -> Ordering {
        if self.major != other.major {
            return if self.major < other.major => Ordering::Less else => Ordering::Greater
        }
        if self.minor != other.minor {
            return if self.minor < other.minor => Ordering::Less else => Ordering::Greater
        }
        return Ordering::Equal
    }

    pub fn op == (const self, other: Version) -> bool {
        return self.major == other.major && self.minor == other.minor
    }
    
    pub fn op != (const self, other: Version) -> bool {
        return !(self == other)
    }

    pub fn op < (const self, other: Version) -> bool {
        return self <=> other == Ordering::Less
    }

    pub fn op <= (const self, other: Version) -> bool {
        return self <=> other != Ordering::Greater
    }

    pub fn op > (const self, other: Version) -> bool {
        return self <=> other == Ordering::Greater
    }

    pub fn op >= (const self, other: Version) -> bool {
        return self <=> other != Ordering::Less
    }
}