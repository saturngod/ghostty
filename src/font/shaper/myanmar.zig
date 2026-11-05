//! Myanmar (Burmese) layout for shaped text runs.
//!
//! The default shaper output pins every glyph to the cell of the codepoint
//! it came from. That works for scripts where each cell is a visual unit,
//! but not for Myanmar: a syllable such as ကြောင် is shaped as one unit,
//! the shaper reorders parts of it (ေ and ြ are drawn before the consonant
//! they follow in memory), and its natural width rarely matches the number
//! of cells the terminal gave it. Pinning glyphs to cells then splits,
//! squeezes, or overlaps the syllable and it becomes unreadable.
//!
//! Instead, we lay Myanmar runs out by orthographic syllable:
//!
//!   - Every glyph keeps its natural position from the shaper relative to
//!     the start of its syllable, so the syllable looks exactly like it
//!     would in any text view.
//!   - Inside a word, syllables follow each other at their natural
//!     spacing, like in any text view. The terminal often gives stacked
//!     forms (္ဘ, kinzi) more cells than they draw, and snapping each
//!     syllable to the grid would open gaps in the middle of a word.
//!   - Each word (and any non-Myanmar text such as a space) starts at the
//!     grid column of its first cell, unless the previous text is still
//!     being drawn there, in which case it starts right after it. Text
//!     never overlaps and is never squeezed; any slack ends up after the
//!     word, where it reads as space.
//!
//! Cells are only used to decide where a word may start. They never cut a
//! syllable apart.
const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");

/// A shaped glyph in visual order, in natural (unsnapped) coordinates
/// relative to the start of the run, in pixels.
pub const Glyph = struct {
    /// The run-relative cell of the codepoint that produced this glyph.
    cluster: u32,

    /// The pen position before this glyph's advance is applied.
    pen: f64,

    /// The natural x position of the glyph (pen plus any glyph offset).
    x: f64,

    /// The advance of this glyph.
    advance: f64,
};

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

/// Joiners and variation selectors stay attached to the text they follow.
fn isJoiner(cp: u32) bool {
    return switch (cp) {
        0x200C, 0x200D, 0xFE00...0xFE0F => true,
        else => false,
    };
}

const virama = 0x1039; // ္ stacks the next consonant under this one
const asat = 0x103A; // ် kills the inherent vowel
const dot_below = 0x1037; // ့ may come before the asat

/// Returns true if any codepoint in the list is Myanmar. The list is any
/// slice of structs with a `codepoint` field.
pub fn containsMyanmar(codepoints: anytype) bool {
    for (codepoints) |c| if (isMyanmar(c.codepoint)) return true;
    return false;
}

/// Returns true if the codepoint at index i starts a new syllable. The
/// list is any slice of structs with a `codepoint` field; entries with a
/// zero codepoint are padding and are skipped.
pub fn startsSyllable(codepoints: anytype, i: usize) bool {
    const cp = codepoints[i].codepoint;
    const prev = prev: {
        var k = i;
        while (k > 0) {
            k -= 1;
            if (codepoints[k].codepoint != 0) break :prev codepoints[k].codepoint;
        }
        break :prev null;
    } orelse return true;

    // Only Myanmar text joins into syllables, plus the joiners that
    // follow it. Everything else is a unit of its own.
    if (!isMyanmar(prev)) return true;
    if (!isMyanmar(cp)) return !isJoiner(cp);

    // A consonant after a virama is stacked under the previous one.
    if (prev == virama) return false;

    // Marks attach to the syllable they follow.
    if (isMark(cp)) return false;

    // A killed consonant (consonant + asat) closes the previous syllable,
    // like the င် in ကြောင်. The exception is kinzi (င်္), which belongs
    // to the consonant that follows it.
    var k = i + 1;
    while (k < codepoints.len and
        (codepoints[k].codepoint == 0 or codepoints[k].codepoint == dot_below)) k += 1;
    if (k < codepoints.len and codepoints[k].codepoint == asat) {
        k += 1;
        while (k < codepoints.len and codepoints[k].codepoint == 0) k += 1;
        if (k >= codepoints.len or codepoints[k].codepoint != virama) return false;
    }

    return true;
}

/// Lay out the shaped glyphs of a run by syllable. `codepoints` is the run
/// input in logical order (structs with `codepoint` and `cluster` fields),
/// `glyphs` is the shaper output in visual order, and `cells` receives the
/// final positions (it must be the same length as `glyphs`; only x and
/// x_offset are written).
pub fn layout(
    alloc: Allocator,
    codepoints: anytype,
    glyphs: []const Glyph,
    cells: []font.shape.Cell,
    cell_width: f64,
) Allocator.Error!void {
    std.debug.assert(glyphs.len == cells.len);
    if (glyphs.len == 0) return;

    // Map every cluster to the cluster that starts its syllable.
    var max_cluster: u32 = 0;
    for (codepoints) |c| max_cluster = @max(max_cluster, c.cluster);
    for (glyphs) |g| max_cluster = @max(max_cluster, g.cluster);
    const starts = try alloc.alloc(u32, max_cluster + 1);
    defer alloc.free(starts);
    for (starts, 0..) |*s, idx| s.* = @intCast(idx);

    // Whether the syllable starting at a cluster may snap to the grid.
    // Only the first syllable of a word (or non-Myanmar text) does.
    const snaps = try alloc.alloc(bool, max_cluster + 1);
    defer alloc.free(snaps);
    @memset(snaps, true);

    // Spaces come from the Myanmar font, whose space is usually narrower
    // than a cell. Give them at least a full cell, like the space in the
    // terminal font, so words don't run together.
    const spaces = try alloc.alloc(bool, max_cluster + 1);
    defer alloc.free(spaces);
    @memset(spaces, false);
    for (codepoints) |c| {
        if (c.codepoint == ' ') spaces[c.cluster] = true;
    }
    {
        var current: u32 = 0;
        var prev_cluster: ?u32 = null;
        var prev_cp: ?u32 = null;
        for (codepoints, 0..) |c, i| {
            if (c.codepoint == 0) continue;
            if (prev_cluster == null or c.cluster != prev_cluster.?) {
                if (prev_cluster == null or startsSyllable(codepoints, i)) {
                    current = c.cluster;
                    snaps[current] = if (prev_cp) |p|
                        !(isMyanmar(p) and isMyanmar(c.codepoint))
                    else
                        true;
                }
                prev_cluster = c.cluster;
            }
            starts[c.cluster] = current;
            prev_cp = c.codepoint;
        }
    }

    // Place the glyphs. Syllables only move forward, so if the shaper
    // ever hands us a glyph of an earlier syllable it is drawn with the
    // current one, which keeps x monotonic as the renderer requires.
    var syllable: ?u32 = null;
    var shift: f64 = 0;
    var pen_end: f64 = 0;
    for (glyphs, cells) |g, *cell| {
        const s = starts[g.cluster];
        if (syllable == null or s > syllable.?) {
            const grid_x = @as(f64, @floatFromInt(s)) * cell_width;
            const start = if (snaps[s]) @max(grid_x, pen_end) else pen_end;
            shift = start - g.pen;
            syllable = s;
        }

        const anchor = syllable.?;
        const anchor_x = @as(f64, @floatFromInt(anchor)) * cell_width;
        const offset = @round(g.x + shift - anchor_x);
        cell.x = @intCast(anchor);
        cell.x_offset = @intFromFloat(std.math.clamp(
            offset,
            std.math.minInt(i16),
            std.math.maxInt(i16),
        ));
        const advance = if (spaces[g.cluster])
            @max(g.advance, cell_width)
        else
            g.advance;
        cell.advance = @intFromFloat(std.math.clamp(
            @round(advance),
            0,
            std.math.maxInt(u16),
        ));
        pen_end = @max(pen_end, g.pen + advance + shift);
    }
}

const TestCp = struct { codepoint: u32, cluster: u32 };

/// Build a codepoint list where every codepoint is its own cluster, the
/// way the terminal stores Myanmar text without grapheme clustering.
fn testCodepoints(comptime str: []const u8) [std.unicode.calcUtf16LeLen(str) catch unreachable]TestCp {
    @setEvalBranchQuota(10_000);
    var result: [std.unicode.calcUtf16LeLen(str) catch unreachable]TestCp = undefined;
    var it = (std.unicode.Utf8View.init(str) catch unreachable).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) {
        result[i] = .{ .codepoint = cp, .cluster = @intCast(i) };
    }
    return result;
}

fn testStarts(cps: []const TestCp) [64]bool {
    var result: [64]bool = @splat(false);
    for (0..cps.len) |i| result[i] = startsSyllable(cps, i);
    return result;
}

test "myanmar: ranges" {
    const testing = std.testing;
    try testing.expect(isMyanmar(0x1000));
    try testing.expect(isMyanmar(0x1031));
    try testing.expect(isMyanmar(0xAA7B));
    try testing.expect(!isMyanmar('a'));
    try testing.expect(isMark(0x1031)); // ေ
    try testing.expect(isMark(0x103C)); // ြ
    try testing.expect(isMark(0x103A)); // ်
    try testing.expect(!isMark(0x1000)); // က
    try testing.expect(!isMark(0x104A)); // ၊
}

test "myanmar: ကြောင် is one syllable" {
    const testing = std.testing;
    const cps = testCodepoints("ကြောင်");
    const starts = testStarts(&cps);
    try testing.expect(starts[0]); // က
    for (1..cps.len) |i| try testing.expect(!starts[i]);
}

test "myanmar: မြန်မာ splits into မြန် and မာ" {
    const testing = std.testing;
    const cps = testCodepoints("မြန်မာ");
    const starts = testStarts(&cps);
    try testing.expect(starts[0]); // မ
    try testing.expect(!starts[1]); // ြ
    try testing.expect(!starts[2]); // န (killed)
    try testing.expect(!starts[3]); // ်
    try testing.expect(starts[4]); // မ
    try testing.expect(!starts[5]); // ာ
}

test "myanmar: stacked consonant stays with its syllable" {
    const testing = std.testing;
    // မ္ဘာ: ဘ is stacked under မ
    const cps = testCodepoints("မ္ဘာ");
    const starts = testStarts(&cps);
    try testing.expect(starts[0]);
    for (1..cps.len) |i| try testing.expect(!starts[i]);
}

test "myanmar: kinzi belongs to the following consonant" {
    const testing = std.testing;
    // အင်္ဂ: အ | င်္ဂ
    const cps = testCodepoints("အင်္ဂ");
    const starts = testStarts(&cps);
    try testing.expect(starts[0]); // အ
    try testing.expect(starts[1]); // င (kinzi)
    try testing.expect(!starts[2]); // ်
    try testing.expect(!starts[3]); // ္
    try testing.expect(!starts[4]); // ဂ
}

test "myanmar: dot below before asat still kills the consonant" {
    const testing = std.testing;
    // ကင့်: the dot below sits between the consonant and the asat
    const cps = testCodepoints("ကင့်");
    const starts = testStarts(&cps);
    try testing.expect(starts[0]);
    try testing.expect(!starts[1]);
    try testing.expect(!starts[2]);
    try testing.expect(!starts[3]);
}

test "myanmar: non-Myanmar text is one unit per codepoint" {
    const testing = std.testing;
    const cps = testCodepoints("ab မ c");
    const starts = testStarts(&cps);
    for (0..cps.len) |i| try testing.expect(starts[i]);
}

test "myanmar: layout keeps reordered glyphs together" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // ကြော + င်, every codepoint in its own cell (cells 0-5), 10px cells.
    const cps = testCodepoints("ကြောင်");

    // Visual order from a shaper: ေ (cluster 2), ြ (1), က (0), ာ (3),
    // င (4), ် (5, zero advance mark).
    const glyphs = [_]Glyph{
        .{ .cluster = 2, .pen = 0, .x = 0, .advance = 6 },
        .{ .cluster = 1, .pen = 6, .x = 6, .advance = 4 },
        .{ .cluster = 0, .pen = 10, .x = 10, .advance = 8 },
        .{ .cluster = 3, .pen = 18, .x = 18, .advance = 5 },
        .{ .cluster = 4, .pen = 23, .x = 23, .advance = 8 },
        .{ .cluster = 5, .pen = 31, .x = 27, .advance = 0 },
    };
    var cells: [glyphs.len]font.shape.Cell = @splat(.{ .x = 0, .glyph_index = 0 });
    try layout(alloc, &cps, &glyphs, &cells, 10);

    // The whole syllable is anchored to its first cell, at its natural
    // positions, so the reordered ေ is drawn first and nothing overlaps.
    for (cells, glyphs) |cell, g| {
        try testing.expectEqual(@as(u16, 0), cell.x);
        try testing.expectEqual(@as(i16, @intFromFloat(g.x)), cell.x_offset);
    }
}

test "myanmar: layout flows syllables inside a word" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // မြန် (cells 0-3) then မာ (cells 4-5), 10px cells. The first syllable
    // is narrower than its 4 cells, but မာ is in the same word, so it
    // follows right after it (20px) instead of leaving a gap.
    const cps = testCodepoints("မြန်မာ");
    const glyphs = [_]Glyph{
        .{ .cluster = 1, .pen = 0, .x = 0, .advance = 4 },
        .{ .cluster = 0, .pen = 4, .x = 4, .advance = 8 },
        .{ .cluster = 2, .pen = 12, .x = 12, .advance = 8 },
        .{ .cluster = 3, .pen = 20, .x = 16, .advance = 0 },
        .{ .cluster = 4, .pen = 20, .x = 20, .advance = 8 },
        .{ .cluster = 5, .pen = 28, .x = 28, .advance = 5 },
    };
    var cells: [glyphs.len]font.shape.Cell = @splat(.{ .x = 0, .glyph_index = 0 });
    try layout(alloc, &cps, &glyphs, &cells, 10);

    for (cells[0..4], glyphs[0..4]) |cell, g| {
        try testing.expectEqual(@as(u16, 0), cell.x);
        try testing.expectEqual(@as(i16, @intFromFloat(g.x)), cell.x_offset);
    }
    try testing.expectEqual(@as(u16, 4), cells[4].x);
    try testing.expectEqual(@as(i16, -20), cells[4].x_offset);
    try testing.expectEqual(@as(u16, 4), cells[5].x);
    try testing.expectEqual(@as(i16, -12), cells[5].x_offset);
}

test "myanmar: spaces are at least one cell wide" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A word wider than its cells, a narrow space, then the next word.
    // 10px cells. ဗာ (cells 0-1) is 26px, the space glyph is only 4px.
    const cps = testCodepoints("ဗာ ဒံ");
    const glyphs = [_]Glyph{
        .{ .cluster = 0, .pen = 0, .x = 0, .advance = 16 },
        .{ .cluster = 1, .pen = 16, .x = 16, .advance = 10 },
        .{ .cluster = 2, .pen = 26, .x = 26, .advance = 4 },
        .{ .cluster = 3, .pen = 30, .x = 30, .advance = 10 },
        .{ .cluster = 4, .pen = 40, .x = 36, .advance = 0 },
    };
    var cells: [glyphs.len]font.shape.Cell = @splat(.{ .x = 0, .glyph_index = 0 });
    try layout(alloc, &cps, &glyphs, &cells, 10);

    // The space starts at 26px and takes a full 10px cell, so ဒံ starts
    // at 36px, not 30px.
    try testing.expectEqual(@as(u16, 10), cells[2].advance);
    try testing.expectEqual(@as(u16, 3), cells[3].x);
    try testing.expectEqual(@as(i16, 6), cells[3].x_offset);
}

test "myanmar: layout snaps words to the grid when there is room" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // မြန် (cells 0-3), a space (cell 4), မာ (cells 5-6), 10px cells.
    // The word and the space are narrower than their cells, so each of
    // them starts at its own grid column.
    const cps = testCodepoints("မြန် မာ");
    const glyphs = [_]Glyph{
        .{ .cluster = 1, .pen = 0, .x = 0, .advance = 4 },
        .{ .cluster = 0, .pen = 4, .x = 4, .advance = 8 },
        .{ .cluster = 2, .pen = 12, .x = 12, .advance = 8 },
        .{ .cluster = 3, .pen = 20, .x = 16, .advance = 0 },
        .{ .cluster = 4, .pen = 20, .x = 20, .advance = 5 },
        .{ .cluster = 5, .pen = 25, .x = 25, .advance = 8 },
        .{ .cluster = 6, .pen = 33, .x = 33, .advance = 5 },
    };
    var cells: [glyphs.len]font.shape.Cell = @splat(.{ .x = 0, .glyph_index = 0 });
    try layout(alloc, &cps, &glyphs, &cells, 10);

    try testing.expectEqual(@as(u16, 4), cells[4].x);
    try testing.expectEqual(@as(i16, 0), cells[4].x_offset);
    try testing.expectEqual(@as(u16, 5), cells[5].x);
    try testing.expectEqual(@as(i16, 0), cells[5].x_offset);
    try testing.expectEqual(@as(u16, 5), cells[6].x);
    try testing.expectEqual(@as(i16, 8), cells[6].x_offset);
}

test "myanmar: layout flows syllables that are wider than their cells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // ကြော in one cell (grapheme clustering) and င် in the next, 10px
    // cells. The first syllable is 23px wide, so the second can't start
    // at cell 1 (10px) and must start after it (23px).
    const cps = [_]TestCp{
        .{ .codepoint = 0x1000, .cluster = 0 },
        .{ .codepoint = 0x103C, .cluster = 0 },
        .{ .codepoint = 0x1031, .cluster = 0 },
        .{ .codepoint = 0x102C, .cluster = 0 },
        .{ .codepoint = 0x1001, .cluster = 1 }, // ခ (not killed)
        .{ .codepoint = 0x1036, .cluster = 1 },
    };
    const glyphs = [_]Glyph{
        .{ .cluster = 0, .pen = 0, .x = 0, .advance = 6 },
        .{ .cluster = 0, .pen = 6, .x = 6, .advance = 4 },
        .{ .cluster = 0, .pen = 10, .x = 10, .advance = 8 },
        .{ .cluster = 0, .pen = 18, .x = 18, .advance = 5 },
        .{ .cluster = 1, .pen = 23, .x = 23, .advance = 8 },
        .{ .cluster = 1, .pen = 31, .x = 27, .advance = 0 },
    };
    var cells: [glyphs.len]font.shape.Cell = @splat(.{ .x = 0, .glyph_index = 0 });
    try layout(alloc, &cps, &glyphs, &cells, 10);

    try testing.expectEqual(@as(u16, 1), cells[4].x);
    try testing.expectEqual(@as(i16, 13), cells[4].x_offset);
    try testing.expectEqual(@as(u16, 1), cells[5].x);
    try testing.expectEqual(@as(i16, 17), cells[5].x_offset);
}
