//! Bot team definitions for the server-side test harness.
//!
//! Mirrors the structure of waves.zig: comptime-constant data describing
//! player-side bot compositions.  The server harness (bot_harness_test.zig)
//! reads these definitions to inject bots into PlayerSlots in place of real
//! WebSocket clients.
//!
//! ## Concepts
//!
//! `Profile`   — a repeating action sequence; on round r the bot submits
//!               moves[r % moves.len].  Profiles are shared across bots.
//!
//! `BotStats`  — explicit HP/attack/defense values with no ClassTag dependency.
//!               attack and defense are stored for future use; only max_hp
//!               affects current combat.
//!
//! `BotEntry`  — one slot in a BotTeam: stats + profile + display name.
//!
//! `BotTeam`   — the player-side analogue of Wave: a named slice of BotEntrys.
//!
//! ## Adding profiles / teams
//!
//! Append a new `pub const profile_*` or `pub const team_*` below.
//! No other file needs to change.

const components = @import("components.zig");

pub const Move = components.ActionChoice;

pub const Profile = struct {
    label: []const u8,
    moves: []const Move,
};

pub const BotStats = struct {
    max_hp: u16,
};

pub const BotEntry = struct {
    name: []const u8,
    stats: BotStats,
    profile: *const Profile,
};

pub const BotTeam = struct {
    label: []const u8,
    bots: []const BotEntry,
};

pub const profile_all_damage = Profile{
    .label = "all_damage",
    .moves = &[_]Move{.damage},
};

pub const profile_all_heal = Profile{
    .label = "all_heal",
    .moves = &[_]Move{.heal},
};

pub const profile_balanced = Profile{
    .label = "balanced",
    .moves = &[_]Move{ .damage, .damage, .shield, .heal },
};

pub const profile_tank = Profile{
    .label = "tank",
    .moves = &[_]Move{ .shield, .shield, .damage },
};

const fighter_stats = BotStats{ .max_hp = 120 };
const tank_stats = BotStats{ .max_hp = 200 };
const cannon_stats = BotStats{ .max_hp = 70 };
const support_stats = BotStats{ .max_hp = 80 };

pub const team_all_damage = BotTeam{
    .label = "team_all_damage",
    .bots = &[_]BotEntry{
        .{ .name = "DmgBot1", .stats = fighter_stats, .profile = &profile_all_damage },
        .{ .name = "DmgBot2", .stats = fighter_stats, .profile = &profile_all_damage },
    },
};

pub const team_mixed = BotTeam{
    .label = "team_mixed",
    .bots = &[_]BotEntry{
        .{ .name = "Tank", .stats = tank_stats, .profile = &profile_all_damage },
        .{ .name = "Medic", .stats = support_stats, .profile = &profile_all_heal },
        .{ .name = "Cannon", .stats = cannon_stats, .profile = &profile_all_damage },
    },
};
