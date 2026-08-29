//! Bot team definitions for the server-side test harness.
//!
//! Mirrors the structure of encounter.zig: comptime-constant data describing
//! player-side bot compositions.  The server harness (bot_harness_test.zig)
//! reads these definitions to inject bots into PlayerSlots in place of real
//! WebSocket clients.
//!
//! ## Concepts
//!
//! `Profile`   — a repeating sequence of move LABELS plus an optional repeating
//!               aim sequence; on cycle r the bot steps aim[r % aim.len], turns
//!               its shape wheel to moves[r % moves.len], and casts.  Shared
//!               across bots.
//!
//! Moves are named by LABEL, not by table index, for the same reason groups are
//! (see balance.zig): a profile keeps meaning the same move when the table is
//! reordered.  The harness resolves the label against the loaded config and
//! rejects a profile naming a move that config does not have.
//!
//! `BotEntry`  — one slot in a BotTeam: profile + display name.
//!
//! `BotTeam`   — a named slice of BotEntrys.
//!
//! ## Adding profiles / teams
//!
//! Append a new `pub const profile_*` or `pub const team_*` below.
//! No other file needs to change.

const protocol = @import("protocol.zig");

pub const Profile = struct {
    label: []const u8,
    /// Move labels to cast, one per cycle, repeating.
    moves: []const []const u8,
    /// Cursor steps taken BEFORE each cast, cycled the same way as `moves`.
    /// A bot that never aims stays wherever it spawned, which is a legitimate
    /// (if bad) strategy — so this defaults to empty rather than being
    /// required.
    aim: []const []const protocol.CursorDir = &.{},

    /// Cursor steps for cycle `n`, or none if this profile never aims.
    pub fn aim_for(self: *const Profile, n: usize) []const protocol.CursorDir {
        if (self.aim.len == 0) return &.{};
        return self.aim[n % self.aim.len];
    }

    /// Label of the move this profile casts on cycle `n`.
    pub fn move_for(self: *const Profile, n: usize) []const u8 {
        return self.moves[n % self.moves.len];
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
    .moves = &.{"poke"},
};

/// Walks LEFT one cell per cast, stamping 3x3 blocks — the field-clearing
/// workhorse.  It heads left because the Lil Guys bite the LEFT columns on
/// every tick of their clock: a hazard reaching column 0 still live is a
/// nibble that fills the hunger clock for nothing.  Clamping means it
/// eventually parks on that edge, which is precisely where a cast is worth
/// the most.
pub const profile_sweeper = Profile{
    .label = "sweeper",
    .moves = &.{"block"},
    .aim = &.{&.{ .left, .left, .left }},
};

/// Alternates a wide sweep and a downward step, snaking down the left side of
/// the field: it opens the door, drops a row, and opens it again.
pub const profile_snake = Profile{
    .label = "snake",
    .moves = &.{ "sweep", "block" },
    .aim = &.{
        &.{ .left, .left, .left },
        &.{ .down, .right, .right },
    },
};

/// Casts nothing but the FREE move: exercises the zero-cost path, and proves a
/// team with an empty pool can still act.
pub const profile_trickle = Profile{
    .label = "trickle",
    .moves = &.{"trickle"},
};

/// Pokes without ever aiming, so two of these converge on the same square and
/// complete `twin_bloom` — the minimal cooperating pair.
pub const profile_twin_bloom = Profile{
    .label = "twin_bloom",
    .moves = &.{"poke"},
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
        .{ .name = "Trickle", .profile = &profile_trickle },
        .{ .name = "Sweeper", .profile = &profile_sweeper },
    },
};
