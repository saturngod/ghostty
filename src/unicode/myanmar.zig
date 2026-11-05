//! Myanmar (Burmese) character classes shared by the terminal and the
//! font shaping code.

/// Returns true if the codepoint is in one of the Myanmar blocks.
pub fn isMyanmar(cp: u32) bool {
    return switch (cp) {
        0x1000...0x109F, // Myanmar
        0xA9E0...0xA9FF, // Myanmar Extended-B
        0xAA60...0xAA7F, // Myanmar Extended-A
        0x116D0...0x116FF, // Myanmar Extended-C
        => true,
        else => false,
    };
}

/// Returns true if the codepoint is a Myanmar combining mark (vowel sign,
/// medial, tone mark, asat, virama, ...). Marks never start a syllable.
pub fn isMark(cp: u32) bool {
    return switch (cp) {
        0x102B...0x103E,
        0x1056...0x1059,
        0x105E...0x1060,
        0x1062...0x1064,
        0x1067...0x106D,
        0x1071...0x1074,
        0x1082...0x108D,
        0x108F,
        0x109A...0x109D,
        0xA9E5,
        0xAA7B...0xAA7D,
        => true,
        else => false,
    };
}

/// Returns true for the spacing marks that programs which turn on
/// grapheme clustering (mode 2027), such as agy, count as zero columns:
/// ေ ျ ြ ၖ ၗ ႄ. Other programs (Codex, vim) count them as one column like
/// any other spacing mark.
pub fn isZeroWidthInClusterMode(cp: u32) bool {
    return switch (cp) {
        0x1031, // ေ vowel sign e
        0x103B, // ျ medial ya
        0x103C, // ြ medial ra
        0x1056, // ၖ vowel sign vocalic r
        0x1057, // ၗ vowel sign vocalic rr
        0x1084, // ႄ vowel sign shan e
        => true,
        else => false,
    };
}
