//! Per-row horizontal flow for Myanmar text.
//!
//! The shaper lays a Myanmar run out at its natural width (see
//! font/shaper/myanmar.zig). That width can be larger than the cells the
//! terminal gave the run, so text after it on the same row would be drawn
//! on top of it. Like a browser, we instead push the following runs right
//! until they clear the Myanmar text. As soon as the text fits its cells
//! again the shift drops back to zero, so the rest of the row stays on the
//! grid.
//!
//! Because text no longer sits exactly on its cells in these rows, the
//! renderer also records where each piece of the row is drawn (see
//! `Segment` and `Rows`). The selection highlight is drawn from those
//! positions and mouse positions are mapped back through them, so selecting
//! Myanmar text follows what is on screen, not the cell grid.
const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");
const myanmar = font.shape.myanmar;

pub const Flow = struct {
    /// Width of a cell in pixels.
    cell_width: i32,

    /// Pixel position where the next run may start drawing.
    end: i32 = 0,

    /// The run being drawn, identified by its starting cell.
    run_offset: ?u16 = null,
    run_cells: u16 = 0,
    run_myanmar: bool = false,

    /// Pixels to add to every glyph of the current run.
    shift: i32 = 0,

    /// Furthest pen position (after advance) of the current Myanmar run.
    pen_end: i32 = 0,

    pub fn init(cell_width: u32) Flow {
        return .{ .cell_width = @intCast(cell_width) };
    }

    /// Call for every cell with the run it belongs to. Starts tracking a
    /// new run when the run changes.
    pub fn enter(
        self: *Flow,
        run: font.shape.TextRun,
        cells: []const terminal.page.Cell,
    ) void {
        if (self.run_offset) |offset| {
            if (offset == run.offset) return;
            self.finish();
        }

        self.run_offset = run.offset;
        self.run_cells = run.cells;
        self.run_myanmar = myanmar: {
            const start: usize = run.offset;
            const end: usize = @min(cells.len, start + run.cells);
            for (cells[start..end]) |cell| {
                if (myanmar.isMyanmar(cell.codepoint())) break :myanmar true;
            }
            break :myanmar false;
        };
        self.shift = @max(0, self.end - self.gridX(run.offset));
        self.pen_end = self.gridX(run.offset) + self.shift;
    }

    /// Append the segments of the current run (after `enter` and `track`
    /// were called for all of its glyphs) to `out`.
    pub fn appendSegments(
        self: *const Flow,
        alloc: Allocator,
        out: *std.ArrayList(Segment),
        run: font.shape.TextRun,
        shaped: []const font.shape.Cell,
    ) Allocator.Error!void {
        const run_end: u16 = run.offset + run.cells;
        if (!self.run_myanmar or shaped.len == 0) {
            try out.append(alloc, .{
                .grid_start = run.offset,
                .grid_end = run_end,
                .px_start = self.gridX(run.offset) + self.shift,
                .px_end = self.gridX(run_end) + self.shift,
                .snap = false,
            });
            return;
        }

        // One segment per syllable. The shaper anchors every glyph of a
        // syllable to the syllable's first cell, so each distinct x is a
        // syllable and it covers the cells up to the next one.
        var i: usize = 0;
        while (i < shaped.len) {
            const anchor = shaped[i].x;
            const grid_x = self.gridX(run.offset + anchor) + self.shift;
            var px_start: i32 = std.math.maxInt(i32);
            var px_end: i32 = std.math.minInt(i32);
            while (i < shaped.len and shaped[i].x == anchor) : (i += 1) {
                const left = grid_x + shaped[i].x_offset;
                px_start = @min(px_start, left);
                px_end = @max(px_end, left + @as(i32, shaped[i].advance));
            }
            const next: u16 = if (i < shaped.len) shaped[i].x else run.cells;
            if (px_end <= px_start) px_end = px_start + self.cell_width;
            try out.append(alloc, .{
                .grid_start = run.offset + anchor,
                .grid_end = run.offset + next,
                .px_start = px_start,
                .px_end = px_end,
                .snap = true,
            });
        }
    }

    /// Call for every shaped glyph of the current run before drawing it.
    pub fn track(self: *Flow, run: font.shape.TextRun, cell: font.shape.Cell) void {
        if (!self.run_myanmar) return;
        const pen = self.gridX(run.offset + cell.x) +
            cell.x_offset +
            @as(i32, cell.advance) +
            self.shift;
        self.pen_end = @max(self.pen_end, pen);
    }

    fn finish(self: *Flow) void {
        const offset = self.run_offset orelse return;
        self.end = if (self.run_myanmar)
            self.pen_end
        else
            self.gridX(offset + self.run_cells) + self.shift;
    }

    fn gridX(self: *const Flow, x: u32) i32 {
        return @as(i32, @intCast(x)) * self.cell_width;
    }
};

/// Squeezes a row whose Myanmar text would be drawn past the right edge.
///
/// Myanmar text is often drawn a little wider than the cells it has, and
/// `Flow` pushes the rest of the row right to make room. At the end of a
/// full row that pushes text past the edge of the window, where it can't
/// be seen. When that happens, everything from the first Myanmar syllable
/// on is moved closer together so the row ends at the edge. Text before
/// it (such as a shell prompt) stays where it is.
pub const Fit = struct {
    /// Pixel position where squeezing starts.
    anchor: i32 = 0,

    /// Pixels after `anchor` are scaled by num / den.
    num: i64 = 1,
    den: i64 = 1,

    pub const none: Fit = .{};

    /// Work out the squeeze for a row, given its segments (see
    /// `Flow.appendSegments`), its cells and its width in pixels.
    pub fn init(
        segments: []const Segment,
        cells: []const terminal.page.Cell,
        width: i32,
        cell_width: i32,
    ) Fit {
        var anchor: ?i32 = null;
        var end: i32 = 0;

        // Width of whatever is drawn last. It keeps its size and ends at
        // the edge, so a syllable in the last column isn't cut off.
        var last_width: i32 = cell_width;

        for (segments) |seg| {
            if (seg.snap) {
                if (anchor == null) anchor = seg.px_start;
                if (seg.px_end >= end) {
                    end = seg.px_end;
                    last_width = seg.px_end - seg.px_start;
                }
                continue;
            }

            // Other text ends at its last cell with text. Empty cells
            // after the text don't count, even if they were pushed right.
            var last: ?u16 = null;
            var x = seg.grid_start;
            while (x < seg.grid_end and x < cells.len) : (x += 1) {
                if (cells[x].hasText()) last = x;
            }
            if (last) |l| {
                const text_end = seg.px_start + (@as(i32, l) + 1 - seg.grid_start) * cell_width;
                if (text_end >= end) {
                    end = text_end;
                    last_width = cell_width;
                }
            }
        }

        var a = anchor orelse return .none;
        if (end <= width) return .none;

        // Squeeze by at most a fifth where possible. If the Myanmar text
        // starts too close to the edge for that, start squeezing earlier
        // in the row: scale = (width - last - a) / (end - last - a) is at
        // least 4/5 when a <= 5 * width - 4 * end - last.
        a = @max(0, @min(a, 5 * width - 4 * end - last_width));

        const num = width - last_width - a;
        const den = end - last_width - a;
        if (num <= 0 or den <= 0) return .none;
        return .{ .anchor = a, .num = num, .den = den };
    }

    /// Where pixel position `px` is drawn after squeezing.
    pub fn apply(self: Fit, px: i32) i32 {
        if (px <= self.anchor) return px;
        const off: i64 = px - self.anchor;
        return self.anchor + @as(i32, @intCast(@divFloor(off * self.num, self.den)));
    }

    /// Squeeze the drawn positions of `segments` the same way.
    pub fn applySegments(self: Fit, segments: []Segment) void {
        if (self.num == self.den) return;
        for (segments) |*seg| {
            seg.px_start = self.apply(seg.px_start);
            seg.px_end = self.apply(seg.px_end);
        }
    }
};

/// How many cells at the start of `cells` are Myanmar marks. When the row
/// before is soft-wrapped and ends in Myanmar text, these marks belong to
/// its last syllable: a wrap split the syllable between the rows.
pub fn leadingMarks(cells: []const terminal.page.Cell) usize {
    var n: usize = 0;
    while (n < cells.len) : (n += 1) {
        const cell = cells[n];
        if (!cell.hasText() or cell.wide != .narrow) break;
        if (!myanmar.isMark(cell.codepoint())) break;
    }
    return n;
}

/// Whether the last cell with text in `cells` is Myanmar.
pub fn endsWithMyanmar(cells: []const terminal.page.Cell) bool {
    var i = cells.len;
    while (i > 0) {
        i -= 1;
        if (cells[i].hasText()) return myanmar.isMyanmar(cells[i].codepoint());
    }
    return false;
}

/// How many leading cells of a row continue a syllable from the row
/// before it, given whether that row is soft-wrapped and its cells.
pub fn splitSyllableCells(
    prev_wrap: bool,
    prev_cells: []const terminal.page.Cell,
    cells: []const terminal.page.Cell,
) usize {
    if (!prev_wrap or !endsWithMyanmar(prev_cells)) return 0;
    return leadingMarks(cells);
}

/// Where a range of cells in a row is drawn, in pixels from the start of
/// the row's grid. Rows without Myanmar text have no segments; their text
/// is exactly on the grid.
pub const Segment = struct {
    /// Cells [grid_start, grid_end).
    grid_start: u16,
    grid_end: u16,

    /// Pixels [px_start, px_end).
    px_start: i32,
    px_end: i32,

    /// True for a Myanmar syllable. The mouse snaps to its edges so a
    /// selection never cuts a syllable apart. Other text maps linearly.
    snap: bool,
};

/// Map a mouse x position (pixels from the start of the row's grid) to the
/// x position on the grid that the rest of Ghostty should see.
pub fn mouseToGrid(segments: []const Segment, px: f64, cell_width: f64) f64 {
    if (segments.len == 0) return px;

    for (segments, 0..) |seg, i| {
        const grid_start = @as(f64, @floatFromInt(seg.grid_start)) * cell_width;
        const grid_end = @as(f64, @floatFromInt(seg.grid_end)) * cell_width;
        const px_start: f64 = @floatFromInt(seg.px_start);
        const px_end: f64 = @floatFromInt(seg.px_end);

        // In the gap before this segment: line up with its start, but
        // never go back before the previous segment's cells.
        if (px < px_start) {
            const grid = grid_start - (px_start - px);
            if (i == 0) return grid;
            const prev_end = @as(f64, @floatFromInt(segments[i - 1].grid_end)) * cell_width;
            return @max(grid, prev_end);
        }

        if (px < px_end) {
            if (seg.snap) {
                return if (px < (px_start + px_end) / 2) grid_start else grid_end;
            }
            return grid_start + (px - px_start) * (grid_end - grid_start) / (px_end - px_start);
        }
    }

    // After the last segment, keep its shift.
    const last = segments[segments.len - 1];
    const grid_end = @as(f64, @floatFromInt(last.grid_end)) * cell_width;
    return grid_end + (px - @as(f64, @floatFromInt(last.px_end)));
}

/// The pixel range [start, end) where cells x0 through x1 (inclusive) are
/// drawn. A partly covered syllable is covered whole.
pub fn cellsToPx(segments: []const Segment, x0: u16, x1: u16, cell_width: i32) [2]i32 {
    return .{
        cellEdge(segments, x0, .start, cell_width),
        cellEdge(segments, x1, .end, cell_width),
    };
}

fn cellEdge(
    segments: []const Segment,
    x: u16,
    comptime edge: enum { start, end },
    cell_width: i32,
) i32 {
    var shift: i32 = 0;
    for (segments) |seg| {
        if (x < seg.grid_start) break;
        if (x < seg.grid_end) {
            if (seg.snap) return switch (edge) {
                .start => seg.px_start,
                .end => seg.px_end,
            };
            const cell_x = seg.px_start + (@as(i32, x) - seg.grid_start) * cell_width;
            return switch (edge) {
                .start => cell_x,
                .end => cell_x + cell_width,
            };
        }
        shift = seg.px_end - @as(i32, seg.grid_end) * cell_width;
    }

    // Not in any segment (e.g. an empty cell): on the grid, plus the shift
    // of the text before it.
    const cell_x = @as(i32, x) * cell_width + @max(0, shift);
    return switch (edge) {
        .start => cell_x,
        .end => cell_x + cell_width,
    };
}

/// The segments of every viewport row, shared between the renderer (which
/// writes them while drawing) and the surface (which maps the mouse through
/// them). Rows without Myanmar text are empty.
pub const Rows = struct {
    mutex: std.Io.Mutex = .init,
    rows: std.ArrayList(std.ArrayList(Segment)) = .empty,

    pub fn deinit(self: *Rows, alloc: Allocator) void {
        for (self.rows.items) |*row| row.deinit(alloc);
        self.rows.deinit(alloc);
    }

    /// Replace the segments of viewport row y.
    pub fn set(
        self: *Rows,
        alloc: Allocator,
        io: std.Io,
        y: usize,
        segments: []const Segment,
    ) Allocator.Error!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // Rows we've never seen and that have nothing to store don't need
        // an entry at all.
        if (y >= self.rows.items.len) {
            if (segments.len == 0) return;
            try self.rows.appendNTimes(alloc, .empty, y + 1 - self.rows.items.len);
        }

        const row = &self.rows.items[y];
        row.clearRetainingCapacity();
        try row.appendSlice(alloc, segments);
    }

    /// Map a mouse x position (pixels from the start of the grid) on
    /// viewport row y. See `mouseToGrid`.
    pub fn mouseToGrid(
        self: *Rows,
        io: std.Io,
        y: usize,
        px: f64,
        cell_width: f64,
    ) f64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (y >= self.rows.items.len) return px;
        return mouseToGridFn(self.rows.items[y].items, px, cell_width);
    }

    /// How far, in pixels, the text at cell x of viewport row y is drawn
    /// from its grid position. Zero for rows without Myanmar text.
    pub fn cellShift(
        self: *Rows,
        io: std.Io,
        y: usize,
        x: u16,
        cell_width: i32,
    ) i32 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (y >= self.rows.items.len) return 0;
        const segments = self.rows.items[y].items;
        if (segments.len == 0) return 0;
        return cellEdge(segments, x, .start, cell_width) - @as(i32, x) * cell_width;
    }
};

const mouseToGridFn = mouseToGrid;

fn testRun(offset: u16, cells: u16) font.shape.TextRun {
    return .{
        .hash = 0,
        .offset = offset,
        .cells = cells,
        .grid = undefined,
        .font_index = .{},
    };
}

test "myanmar flow: text after an overflowing Myanmar run moves right" {
    const testing = std.testing;

    // Cells: 4 Myanmar cells, then "|" at cell 4. 10px cells.
    var cells: [5]terminal.page.Cell = @splat(.init(0x1000));
    cells[4] = .init('|');

    var flow: Flow = .init(10);

    // The Myanmar run draws 46px wide, 6px past its 4 cells.
    const mm = testRun(0, 4);
    flow.enter(mm, &cells);
    try testing.expectEqual(@as(i32, 0), flow.shift);
    flow.track(mm, .{ .x = 0, .x_offset = 0, .advance = 20, .glyph_index = 0 });
    flow.track(mm, .{ .x = 0, .x_offset = 20, .advance = 26, .glyph_index = 0 });

    // The "|" moves right by 6px to clear it.
    const bar = testRun(4, 1);
    flow.enter(bar, &cells);
    try testing.expectEqual(@as(i32, 6), flow.shift);
}

test "myanmar flow: the row returns to the grid when Myanmar text fits" {
    const testing = std.testing;

    var cells: [6]terminal.page.Cell = @splat(.init(0x1000));
    cells[4] = .init('a');
    cells[5] = .init('b');

    var flow: Flow = .init(10);

    // Myanmar run narrower than its 4 cells.
    const mm = testRun(0, 4);
    flow.enter(mm, &cells);
    flow.track(mm, .{ .x = 0, .x_offset = 0, .advance = 33, .glyph_index = 0 });

    const ab = testRun(4, 2);
    flow.enter(ab, &cells);
    try testing.expectEqual(@as(i32, 0), flow.shift);
}

test "myanmar flow: a shift carries across following non-Myanmar runs" {
    const testing = std.testing;

    var cells: [7]terminal.page.Cell = @splat(.init(0x1000));
    cells[2] = .init('a');
    cells[3] = .init('b');
    cells[4] = .init('c');

    var flow: Flow = .init(10);

    const mm = testRun(0, 2);
    flow.enter(mm, &cells);
    flow.track(mm, .{ .x = 0, .x_offset = 0, .advance = 25, .glyph_index = 0 });

    // "ab" (cells 2-3) is pushed 5px right, and so is "c" after it,
    // even though they are separate runs (e.g. a style change).
    const ab = testRun(2, 2);
    flow.enter(ab, &cells);
    try testing.expectEqual(@as(i32, 5), flow.shift);
    const c = testRun(4, 1);
    flow.enter(c, &cells);
    try testing.expectEqual(@as(i32, 5), flow.shift);
}

test "myanmar flow: segments per syllable" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A Myanmar run of 5 cells with two syllables anchored at cells 0
    // and 3, 10px cells. The first is 34px wide, the second 26px.
    var cells: [5]terminal.page.Cell = @splat(.init(0x1000));
    var flow: Flow = .init(10);
    const run = testRun(0, 5);
    const shaped = [_]font.shape.Cell{
        .{ .x = 0, .x_offset = 0, .advance = 20, .glyph_index = 0 },
        .{ .x = 0, .x_offset = 20, .advance = 14, .glyph_index = 0 },
        .{ .x = 3, .x_offset = 4, .advance = 26, .glyph_index = 0 },
    };
    flow.enter(run, &cells);
    for (shaped) |c| flow.track(run, c);

    var segs: std.ArrayList(Segment) = .empty;
    defer segs.deinit(alloc);
    try flow.appendSegments(alloc, &segs, run, &shaped);

    try testing.expectEqual(@as(usize, 2), segs.items.len);
    try testing.expectEqual(Segment{ .grid_start = 0, .grid_end = 3, .px_start = 0, .px_end = 34, .snap = true }, segs.items[0]);
    try testing.expectEqual(Segment{ .grid_start = 3, .grid_end = 5, .px_start = 34, .px_end = 60, .snap = true }, segs.items[1]);
}

test "myanmar flow: mouse snaps to syllable edges" {
    const testing = std.testing;
    const segs = [_]Segment{
        .{ .grid_start = 0, .grid_end = 3, .px_start = 0, .px_end = 34, .snap = true },
        .{ .grid_start = 3, .grid_end = 5, .px_start = 34, .px_end = 60, .snap = true },
        // "|" pushed 10px right of its cell 5.
        .{ .grid_start = 5, .grid_end = 6, .px_start = 60, .px_end = 70, .snap = false },
    };

    // Left half of the first syllable: its start. Right half: its end.
    try testing.expectEqual(@as(f64, 0), mouseToGrid(&segs, 5, 10));
    try testing.expectEqual(@as(f64, 30), mouseToGrid(&segs, 25, 10));

    // The last pixels of the second syllable (drawn at 34-60, on cells
    // 3-4) select through its end, not into the "|".
    try testing.expectEqual(@as(f64, 50), mouseToGrid(&segs, 58, 10));

    // The middle of the shifted "|" maps to the middle of its cell.
    try testing.expectEqual(@as(f64, 55), mouseToGrid(&segs, 65, 10));

    // Past the end keeps the shift.
    try testing.expectEqual(@as(f64, 72), mouseToGrid(&segs, 82, 10));

    // No segments: unchanged.
    try testing.expectEqual(@as(f64, 42), mouseToGrid(&.{}, 42, 10));
}

test "myanmar flow: highlight covers whole syllables at drawn positions" {
    const testing = std.testing;
    const segs = [_]Segment{
        .{ .grid_start = 0, .grid_end = 3, .px_start = 0, .px_end = 34, .snap = true },
        .{ .grid_start = 3, .grid_end = 5, .px_start = 34, .px_end = 60, .snap = true },
        .{ .grid_start = 5, .grid_end = 6, .px_start = 60, .px_end = 70, .snap = false },
    };

    // Cells 1-3 touch both syllables, so both are highlighted whole.
    try testing.expectEqual([2]i32{ 0, 60 }, cellsToPx(&segs, 1, 3, 10));

    // The shifted "|" alone.
    try testing.expectEqual([2]i32{ 60, 70 }, cellsToPx(&segs, 5, 5, 10));

    // An empty cell after the text keeps the shift.
    try testing.expectEqual([2]i32{ 80, 90 }, cellsToPx(&segs, 7, 7, 10));
}

test "myanmar flow: shared rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var rows: Rows = .{};
    defer rows.deinit(alloc);

    // Unknown rows are unchanged.
    try testing.expectEqual(@as(f64, 25), rows.mouseToGrid(testing.io, 3, 25, 10));

    const segs = [_]Segment{
        .{ .grid_start = 0, .grid_end = 3, .px_start = 0, .px_end = 34, .snap = true },
    };
    try rows.set(alloc, testing.io, 3, &segs);
    try testing.expectEqual(@as(f64, 30), rows.mouseToGrid(testing.io, 3, 25, 10));

    // The cursor after the text moves with it: the syllable ends at 34px,
    // 4px past its 3 cells.
    try testing.expectEqual(@as(i32, 4), rows.cellShift(testing.io, 3, 3, 10));
    try testing.expectEqual(@as(i32, 0), rows.cellShift(testing.io, 9, 3, 10));

    // Clearing a row makes it unchanged again.
    try rows.set(alloc, testing.io, 3, &.{});
    try testing.expectEqual(@as(f64, 25), rows.mouseToGrid(testing.io, 3, 25, 10));
}

test "myanmar flow: a row drawn past the edge is squeezed to fit" {
    const testing = std.testing;

    // "ab" then two Myanmar syllables in a 100px (10 cell) row of 10px
    // cells. They draw 40px and 50px wide, so the row ends at 110px.
    var cells: [10]terminal.page.Cell = @splat(.init(0x1000));
    cells[0] = .init('a');
    cells[1] = .init('b');
    const segs = [_]Segment{
        .{ .grid_start = 0, .grid_end = 2, .px_start = 0, .px_end = 20, .snap = false },
        .{ .grid_start = 2, .grid_end = 5, .px_start = 20, .px_end = 60, .snap = true },
        .{ .grid_start = 5, .grid_end = 10, .px_start = 60, .px_end = 110, .snap = true },
    };

    const fit: Fit = .init(&segs, &cells, 100, 10);

    // The last syllable keeps its width and ends at the edge.
    try testing.expectEqual(@as(i32, 50), fit.apply(60));

    // Squeezing starts early enough to stay within a fifth: here from
    // 10px, so "a" stays put and "b" moves very little.
    try testing.expectEqual(@as(i32, 0), fit.apply(0));
    try testing.expectEqual(@as(i32, 10), fit.apply(10));
    try testing.expectEqual(@as(i32, 18), fit.apply(20));
}

test "myanmar flow: a syllable in the last column is kept whole" {
    const testing = std.testing;

    // 9 letters then a 25px syllable in the last 10px cell of a 100px row.
    var cells: [10]terminal.page.Cell = @splat(.init('x'));
    cells[9] = .init(0x1000);
    const segs = [_]Segment{
        .{ .grid_start = 0, .grid_end = 9, .px_start = 0, .px_end = 90, .snap = false },
        .{ .grid_start = 9, .grid_end = 10, .px_start = 90, .px_end = 115, .snap = true },
    };

    const fit: Fit = .init(&segs, &cells, 100, 10);

    // The syllable starts 25px before the edge, so it ends at the edge.
    try testing.expectEqual(@as(i32, 75), fit.apply(90));
    try testing.expectEqual(@as(i32, 0), fit.apply(0));
}

test "myanmar flow: a row that fits is not squeezed" {
    const testing = std.testing;

    var cells: [6]terminal.page.Cell = @splat(.init(0x1000));
    cells[5] = .init(0);
    const segs = [_]Segment{
        .{ .grid_start = 0, .grid_end = 5, .px_start = 0, .px_end = 55, .snap = true },
        // Empty cells pushed right past the edge don't count.
        .{ .grid_start = 5, .grid_end = 6, .px_start = 55, .px_end = 65, .snap = false },
    };

    const fit: Fit = .init(&segs, &cells, 60, 10);
    try testing.expectEqual(@as(i32, 58), fit.apply(58));
    try testing.expectEqual(@as(i32, 65), fit.apply(65));
}

test "myanmar flow: marks a wrap moved to the next row" {
    const testing = std.testing;

    // ရေးသာ | း...: the row ends in Myanmar and the next starts with း.
    var prev: [4]terminal.page.Cell = undefined;
    for (&prev, [_]u21{ 0x101B, 0x1031, 0x1038, 0x101E }) |*c, cp| c.* = .init(cp);
    var next: [3]terminal.page.Cell = undefined;
    for (&next, [_]u21{ 0x102C, 0x1038, 0x1000 }) |*c, cp| c.* = .init(cp);

    // ာ and း continue the syllable; က starts a new one.
    try testing.expectEqual(@as(usize, 2), splitSyllableCells(true, &prev, &next));

    // Not soft-wrapped: a new line that happens to start with a mark.
    try testing.expectEqual(@as(usize, 0), splitSyllableCells(false, &prev, &next));

    // The row before ends in other text.
    var ascii: [2]terminal.page.Cell = .{ .init('a'), .init('b') };
    try testing.expectEqual(@as(usize, 0), splitSyllableCells(true, &ascii, &next));
}
