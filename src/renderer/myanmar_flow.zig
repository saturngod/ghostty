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
//! Only glyph positions move. Backgrounds, the cursor, and decorations
//! stay on the grid.
const std = @import("std");
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
