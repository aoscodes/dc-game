//! Bot team definitions for the server-side test harness.
//!
//! Mirrors the structure of encounter.zig: comptime-constant data describing
//! player-side bot compositions.  The server harness (bot_harness_test.zig)
//! reads these definitions to inject bots into PlayerSlots in place of real
//! WebSocket clients.
//!
//! ## Concepts
//!
//! `Profile`   — a repeating combo sequence plus an optional repeating aim
//!               sequence; on cycle r the bot steps aim[r % aim.len] then
//!               submits combos[r % combos.len].  Shared across bots.
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
const protocol = @import("protocol.zig");

const mk = c.make_combo;

const D = c.ComboSlot{ .action = .dispense };
const M = c.ComboSlot{ .action = .medicine };

pub const Profile = struct {
    label: []const u8,
    combos: []const c.ActionCombo,
    /// Cursor steps taken BEFORE each cast, cycled the same way as `combos`.
    /// A bot that never aims stays wherever it spawned, which is a legitimate
    /// (if bad) strategy — so this defaults to empty rather than being
    /// required.
    aim: []const []const protocol.CursorDir = &.{},

    /// Cursor steps for cycle `n`, or none if this profile never aims.
    pub fn aim_for(self: *const Profile, n: usize) []const protocol.CursorDir {
        if (self.aim.len == 0) return &.{};
        return self.aim[n % self.aim.len];
    }
};

pub const BotEntry = struct {
    name: []const u8,
    profile: *const Profile,
};

pub const BotTeam = struct {
    label: []const u8,
    bots: []const BotEntry,
};

/// Pokes a single cell, never moving: the minimum viable player.
pub const profile_poker = Profile{
    .label = "poker",
    .combos = &[_]c.ActionCombo{mk(&.{D})},
};

/// Walks right one cell per cast, stamping 3x3 blocks — the field-clearing
/// workhorse.  Clamping means it eventually parks on the right edge.
pub const profile_sweeper = Profile{
    .label = "sweeper",
    .combos = &[_]c.ActionCombo{mk(&.{ D, D, D })},
    .aim = &.{&.{ .right, .right, .right }},
};

/// Alternates a wide sweep and a downward step, snaking across the field.
pub const profile_snake = Profile{
    .label = "snake",
    .combos = &[_]c.ActionCombo{
        mk(&.{ D, D }),
        mk(&.{ D, D, D }),
    },
    .aim = &.{
        &.{ .right, .right, .right },
        &.{ .down, .left, .left },
    },
};

/// Brews medicine instead of clearing: exercises the healing path.
pub const profile_medic = Profile{
    .label = "medic",
    .combos = &[_]c.ActionCombo{mk(&.{ M, M })},
};

/// One half of the twin_bloom team recipe, every cycle.
pub const profile_twin_bloom = Profile{
    .label = "twin_bloom",
    .combos = &[_]c.ActionCombo{mk(&.{ D, M })},
};

pub const team_bloom_pair = BotTeam{
    .label = "team_bloom_pair",
    .bots = &[_]BotEntry{
        .{ .name = "BloomBotA", .profile = &profile_twin_bloom },
        .{ .name = "BloomBotB", .profile = &profile_twin_bloom },
    },
};

pub const team_mixed = BotTeam{
    .label = "team_mixed",
    .bots = &[_]BotEntry{
        .{ .name = "Snake", .profile = &profile_snake },
        .{ .name = "Medic", .profile = &profile_medic },
        .{ .name = "Sweeper", .profile = &profile_sweeper },
    },
};
