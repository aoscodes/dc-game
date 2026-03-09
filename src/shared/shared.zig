//! Shared module root.  Re-exports all shared types for consumers.
//!
//! Import as: const shared = @import("shared");
//! Then use:  shared.components.Health, shared.protocol.MsgTag, etc.

pub const components = @import("components.zig");
pub const protocol = @import("protocol.zig");
pub const transport = @import("transport.zig");
pub const waves = @import("waves.zig");
pub const game_logic = @import("game_logic.zig");

// Convenience re-exports of the most-used types at the top level.
pub const Transport = transport.Transport;
pub const GridPos = components.GridPos;
pub const ClassTag = components.ClassTag;
pub const TeamId = components.TeamId;
pub const MsgTag = protocol.MsgTag;

test {
    // Pull in all test blocks from sub-modules.
    _ = @import("components.zig");
    _ = @import("protocol.zig");
    _ = @import("transport.zig");
    _ = @import("waves.zig");
    _ = @import("game_logic.zig");
}
