//! tmux control mode follower backend.
//!
//! A follower surface mirrors one tmux pane. The pane lives in the tmux
//! server, so there is no pty and no subprocess here: writes are handed
//! to the app thread, which turns them into `send-keys` on the gateway,
//! and reads are injected by the gateway when it receives `%output`.
//!
//! Writes cross the thread boundary through the surface mailbox rather
//! than reaching into the session directly, because the session is owned
//! by the app thread. Output goes the other way through `queueOutput`,
//! which only appends to a buffer: the app thread drains its own mailbox,
//! so it must never wait on a follower. A reader thread parses the
//! buffer, as the exec backend's read thread does with its pty. Parsing
//! on the IO thread instead would deadlock it on its own mailbox, which
//! the stream handler fills with replies while it parses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_tmux);

pub const Tmux = @This();

alloc: Allocator,

/// The tmux pane id (the number in `%3`) this surface mirrors.
pane_id: usize,

/// Pane output and grid changes in control-stream order. Both must be
/// consumed by the same reader: sending grids to the IO thread lets a
/// redraw overtake its resize, or a resize overtake older pane output.
/// `quit` tells the reader to stop. Guarded by `output_mutex`.
output: Output = .{},
quit: bool = false,
output_mutex: std.Io.Mutex = .init,
output_cond: std.Io.Condition = .init,

/// Set when we enter the IO thread. See the note above about why we go
/// through the mailbox.
surface_mailbox: ?apprt.surface.Mailbox = null,

/// The last size we told tmux about. The GUI resizes us on every layout
/// pass, and most of those don't change the grid at all.
last_size: ?renderer.GridSize = null,

pub fn init(alloc: Allocator, pane_id: usize) Tmux {
    return .{ .alloc = alloc, .pane_id = pane_id };
}

pub fn deinit(self: *Tmux) void {
    self.output.deinit(self.alloc);
}

/// Queue pane output for the reader thread. Safe to call from any
/// thread; it only appends, so the caller never waits on the reader.
pub fn queueOutput(self: *Tmux, data: []const u8) Allocator.Error!void {
    self.output_mutex.lockUncancelable(global.io());
    defer self.output_mutex.unlock(global.io());
    try self.output.bytes.appendSlice(self.alloc, data);
    self.output_cond.signal(global.io());
}

/// Queue a grid change at this exact position in the pane's output.
pub fn queueGrid(self: *Tmux, grid: renderer.GridSize) Allocator.Error!void {
    self.output_mutex.lockUncancelable(global.io());
    defer self.output_mutex.unlock(global.io());
    try self.output.grids.append(self.alloc, .{
        .offset = self.output.bytes.items.len,
        .size = grid,
    });
    self.output_cond.signal(global.io());
}

/// Parse queued pane output until threadExit sets `quit`.
fn readerMain(self: *Tmux, io: *termio.Termio) void {
    while (true) {
        var output = output: {
            self.output_mutex.lockUncancelable(global.io());
            defer self.output_mutex.unlock(global.io());
            while (self.output.empty() and !self.quit) {
                self.output_cond.waitUncancelable(global.io(), &self.output_mutex);
            }
            if (self.quit) return;

            const output = self.output;
            self.output = .{};
            break :output output;
        };
        defer output.deinit(self.alloc);
        output.process(io) catch |err| {
            log.warn("error applying tmux pane grid err={}", .{err});
        };
    }
}

const Output = struct {
    bytes: std.ArrayList(u8) = .empty,
    grids: std.ArrayList(struct { offset: usize, size: renderer.GridSize }) = .empty,

    fn empty(self: *const Output) bool {
        return self.bytes.items.len == 0 and self.grids.items.len == 0;
    }

    fn deinit(self: *Output, alloc: Allocator) void {
        self.bytes.deinit(alloc);
        self.grids.deinit(alloc);
    }

    fn process(self: *const Output, io: *termio.Termio) !void {
        var offset: usize = 0;
        for (self.grids.items) |grid| {
            if (offset < grid.offset) io.processOutput(self.bytes.items[offset..grid.offset]);
            try io.setGridOverride(grid.size);
            offset = grid.offset;
        }
        if (offset < self.bytes.items.len) io.processOutput(self.bytes.items[offset..]);
    }
};

pub fn initTerminal(self: *Tmux, term: *terminal.Terminal) void {
    _ = self;
    _ = term;
}

pub fn threadEnter(
    self: *Tmux,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;
    self.surface_mailbox = io.surface_mailbox;

    const reader = try std.Thread.spawn(.{}, readerMain, .{ self, io });
    reader.setName(global.io(), "io-tmux-reader") catch {};
    td.backend = .{ .tmux = .{ .reader = reader } };

    // A follower whose grid tmux decides has nothing to announce: the
    // session already knows the pane's size and asks for its contents
    // itself.
    if (io.grid_override != null) return;

    // Announce the size we start at. Nothing resizes a surface that opens
    // at the size it keeps, and the session wants the size before it asks
    // tmux what is on the pane.
    const grid_size = io.size.grid();
    self.last_size = grid_size;
    self.send(.{ .tmux_resize = grid_size });
}

pub fn threadExit(self: *Tmux, td: *termio.Termio.ThreadData) void {
    {
        self.output_mutex.lockUncancelable(global.io());
        defer self.output_mutex.unlock(global.io());
        self.quit = true;
        self.output_cond.signal(global.io());
    }
    td.backend.tmux.reader.join();
    self.surface_mailbox = null;
}

pub fn focusGained(
    self: *Tmux,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Tmux,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = screen_size;

    if (self.last_size) |last| {
        if (last.columns == grid_size.columns and
            last.rows == grid_size.rows) return;
    }
    self.last_size = grid_size;

    self.send(.{ .tmux_resize = grid_size });
}

pub fn queueWrite(
    self: *Tmux,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;
    _ = linefeed;
    if (data.len == 0) return;

    const req: apprt.surface.Message.WriteReq = try .init(alloc, data);
    self.send(.{ .tmux_send_keys = req });
}

fn send(self: *Tmux, msg: apprt.surface.Message) void {
    var mailbox = self.surface_mailbox orelse return;
    _ = mailbox.push(msg, .{ .forever = {} });
}

pub fn childExitedAbnormally(
    self: *Tmux,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub fn getProcessInfo(self: *Tmux, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

pub const ThreadData = struct {
    /// Parses the queued pane output. See readerMain.
    reader: std.Thread,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

pub const Config = struct {
    pane_id: usize,
};

test "tmux reader orders grid changes with old and new pane output" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const configpkg = @import("../config.zig");
    var config = try configpkg.Config.default(alloc);
    defer config.deinit();
    var wakeup = try global.xev.Async.init();
    defer wakeup.deinit();
    const mailbox = try renderer.Thread.Mailbox.create(alloc);
    defer mailbox.destroy(alloc);
    var mutex: std.Io.Mutex = .init;
    var io: termio.Termio = undefined;
    var state: renderer.State = .{ .mutex = &mutex, .terminal = &io.terminal };
    const pixels: renderer.Size = .{
        .screen = .{ .width = 40, .height = 40 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{},
    };
    const derived = try termio.Termio.DerivedConfig.init(alloc, &config);
    io = .{
        .alloc = alloc,
        .terminal = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 4, .rows = 2 }),
        .size = pixels,
        .grid_override = .{ .columns = 4, .rows = 2 },
        .config = derived,
        .backend = .{ .tmux = .init(alloc, 0) },
        .mailbox = try termio.Mailbox.initSPSC(alloc),
        .renderer_state = &state,
        .renderer_wakeup = wakeup,
        .renderer_mailbox = mailbox,
        // These sequences never send app messages; no GTK objects needed.
        .surface_mailbox = undefined,
        .terminal_stream = .init(.{
            .allocator = alloc,
            .handler = .{
                .alloc = alloc,
                .terminal = &io.terminal,
                .size = &io.size,
                .grid_override = &io.grid_override,
                .termio_mailbox = &io.mailbox,
                .surface_mailbox = undefined,
                .renderer_state = &state,
                .renderer_wakeup = wakeup,
                .renderer_mailbox = mailbox,
                .enquiry_response = derived.enquiry_response,
                .osc_color_report_format = derived.osc_color_report_format,
                .clipboard_write = derived.clipboard_write,
                .clipboard_write_limit = derived.clipboard_write_limit,
                .xt_checksum_report = derived.xt_checksum_report,
                .tmux_follower = true,
            },
        }),
    };
    defer io.deinit();

    // Leave the IO mailbox undrained, as when its thread is delayed.
    // Native pixel resizes must not hold up a server grid or its redraw.
    io.queueMessage(.{ .resize = pixels }, .unlocked);
    io.tmuxQueueOutput("\x1b[?1049habcdefgh");
    try io.tmuxQueueGrid(.{ .columns = 8, .rows = 4 });
    io.tmuxQueueOutput("\x1b[4;8HZ");
    const tmux = &io.backend.tmux;
    try tmux.output.process(&io);
    tmux.output.deinit(alloc);
    tmux.output = .{};
    {
        // Old output wraps at four columns, new output addresses row 4,
        // column 8. Neither direction may overtake the other.
        const text = try io.terminal.screens.active.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(text);
        try testing.expectEqualStrings("abcd\nefgh\n\n       Z", text);
        try testing.expectEqual(8, io.terminal.cols);
        try testing.expectEqual(4, io.terminal.rows);
        try testing.expect(io.mailbox.spsc.queue.pop(testing.io).? == .resize);
    }

    // A grid at the end of one reader batch still precedes output in the
    // next. The resize itself must wake the reader even without output.
    try io.tmuxQueueGrid(.{ .columns = 4, .rows = 2 });
    try testing.expect(!tmux.output.empty());
    try tmux.output.process(&io);
    tmux.output.deinit(alloc);
    tmux.output = .{};
    try testing.expectEqual(4, io.terminal.cols);
    try testing.expectEqual(2, io.terminal.rows);
    io.tmuxQueueOutput("\x1b[2J\x1b[Hnew!\x1b[2;1Hdone");
    try tmux.output.process(&io);
    {
        const text = try io.terminal.screens.active.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(text);
        try testing.expectEqualStrings("new!\ndone", text);
    }
}
