pub const components = @import("components.zig");
pub const protocol = @import("protocol.zig");
pub const transport = @import("transport.zig");
pub const encounter = @import("encounter.zig");
pub const game_logic = @import("game_logic.zig");
pub const bots = @import("bots.zig");
pub const balance = @import("balance.zig");
pub const config = @import("config.zig");
pub const fixtures = @import("fixtures.zig");

pub const Transport = transport.Transport;
pub const BufferTransport = transport.BufferTransport;

test {
    _ = @import("components.zig");
    _ = @import("protocol.zig");
    _ = @import("transport.zig");
    _ = @import("encounter.zig");
    _ = @import("game_logic.zig");
    _ = @import("bots.zig");
    _ = @import("balance.zig");
    _ = @import("config.zig");
    _ = @import("fixtures.zig");
}
