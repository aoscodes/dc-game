//! Bot team definitions for the server-side test harness.
//!
//! Mirrors the structure of encounter.zig: comptime-constant data describing
//! player-side bot compositions.  The server harness (bot_harness_test.zig)
//! reads these definitions to inject bots into PlayerSlots in place of real
//! WebSocket clients.
//!
//! ## Concepts
//!
//! `Profile`   — a repeating combo sequence; on round r the bot submits
//!               combos[r % combos.len].  Profiles are shared across bots.
//!
//! `BotEntry`  — one slot in a BotTeam: profile + display name.
//!
//! `BotTeam`   — a named slice of BotEntrys.
//!
//! ## Adding profiles / teams
//!
//! Append a new `pub const profile_*` or `pub const team_*` below.
//! No other file needs to change.

const c = @import("components.zig");

const mk = c.make_combo;

pub const Profile = struct {
    label: []const u8,
    combos: []const c.ActionCombo,
};

pub const BotEntry = struct {
    name: []const u8,
    profile: *const Profile,
};

pub const BotTeam = struct {
    label: []const u8,
    bots: []const BotEntry,
};

/// Dispenses red agents every round (flat conversion: 2 slots).
pub const profile_red_dispenser = Profile{
    .label = "red_dispenser",
    .combos = &[_]c.ActionCombo{
        mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } }),
    },
};

/// Rotates through all four agent colors, one flood recipe per round.
pub const profile_rainbow = Profile{
    .label = "rainbow",
    .combos = &[_]c.ActionCombo{
        mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }),
        mk(&.{ .{ .element = .green }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }),
        mk(&.{ .{ .element = .yellow }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }),
        mk(&.{ .{ .element = .blue }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }),
    },
};

/// Casts medicine every round (panacea recipe).
pub const profile_medic = Profile{
    .label = "medic",
    .combos = &[_]c.ActionCombo{
        mk(&.{ .{ .element = .blue }, .{ .action = .medicine }, .{ .action = .medicine } }),
    },
};

/// One half of the twin_flames team recipe, every round.
pub const profile_twin_flame = Profile{
    .label = "twin_flame",
    .combos = &[_]c.ActionCombo{
        mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } }),
    },
};

pub const team_red_pair = BotTeam{
    .label = "team_red_pair",
    .bots = &[_]BotEntry{
        .{ .name = "FlameBotA", .profile = &profile_twin_flame },
        .{ .name = "FlameBotB", .profile = &profile_twin_flame },
    },
};

pub const team_mixed = BotTeam{
    .label = "team_mixed",
    .bots = &[_]BotEntry{
        .{ .name = "Rainbow", .profile = &profile_rainbow },
        .{ .name = "Medic", .profile = &profile_medic },
        .{ .name = "Sprayer", .profile = &profile_red_dispenser },
    },
};
