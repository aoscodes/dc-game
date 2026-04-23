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

/// One action step in a bot's repeating sequence.
pub const Move = components.ActionChoice;

/// A repeating action sequence.  On round r the bot chooses moves[r % moves.len].
pub const Profile = struct {
    label: []const u8,
    /// Must be non-empty; the harness asserts this at init time.
    moves: []const Move,
};

/// Fully explicit stat block for a bot.  No ClassTag required.
/// Only max_hp participates in current combat; attack/defense are reserved.
pub const BotStats = struct {
    max_hp: u16,
    /// Reserved for future combat extensions; not used by game_logic today.
    attack: u16 = 0,
    defense: u16 = 0,
};

/// One bot slot within a BotTeam.
pub const BotEntry = struct {
    /// Display name shown in lobby broadcasts (max 16 chars; truncated if longer).
    name: []const u8,
    stats: BotStats,
    profile: *const Profile,
};

/// A named player-side team configuration for test harness injection.
pub const BotTeam = struct {
    label: []const u8,
    /// Length must be <= MAX_PLAYERS (6).  The harness enforces this at init time.
    bots: []const BotEntry,
};

// ---------------------------------------------------------------------------
// Pre-defined profiles
// ---------------------------------------------------------------------------

/// Spam damage every round.
pub const profile_all_damage = Profile{
    .label = "all_damage",
    .moves = &[_]Move{.damage},
};

/// Spam heal every round.
pub const profile_all_heal = Profile{
    .label = "all_heal",
    .moves = &[_]Move{.heal},
};

/// Spam shield every round.
pub const profile_all_shield = Profile{
    .label = "all_shield",
    .moves = &[_]Move{.shield},
};

/// Balanced rotation: two damage, one shield, one heal.
pub const profile_balanced = Profile{
    .label = "balanced",
    .moves = &[_]Move{ .damage, .damage, .shield, .heal },
};

/// Tank rotation: two shields then one damage.
pub const profile_tank = Profile{
    .label = "tank",
    .moves = &[_]Move{ .shield, .shield, .damage },
};

// ---------------------------------------------------------------------------
// Stat presets (named for readability in team definitions below)
// ---------------------------------------------------------------------------

/// Stat block matching the fighter class defaults.
const fighter_stats = BotStats{ .max_hp = 120, .attack = 20, .defense = 14 };

/// High-HP tank stat block.
const tank_stats = BotStats{ .max_hp = 200, .attack = 10, .defense = 20 };

/// Glass-cannon stat block: low HP, high attack.
const cannon_stats = BotStats{ .max_hp = 70, .attack = 28, .defense = 5 };

/// Support stat block: moderate HP, low attack.
const support_stats = BotStats{ .max_hp = 80, .attack = 10, .defense = 8 };

// ---------------------------------------------------------------------------
// Pre-defined bot teams
// ---------------------------------------------------------------------------

/// Two fighters that always deal damage.
/// Good baseline: measures raw DPS throughput against a wave.
pub const team_all_damage = BotTeam{
    .label = "team_all_damage",
    .bots = &[_]BotEntry{
        .{ .name = "DmgBot1", .stats = fighter_stats, .profile = &profile_all_damage },
        .{ .name = "DmgBot2", .stats = fighter_stats, .profile = &profile_all_damage },
    },
};

/// One healer bot only — never deals damage.
/// Used to verify that a team with no damage output eventually loses.
pub const team_all_heal = BotTeam{
    .label = "team_all_heal",
    .bots = &[_]BotEntry{
        .{ .name = "HealBot", .stats = support_stats, .profile = &profile_all_heal },
    },
};

/// Mixed composition: high-HP damage dealer, dedicated healer, glass-cannon.
/// Exercises all three action types simultaneously.
pub const team_mixed = BotTeam{
    .label = "team_mixed",
    .bots = &[_]BotEntry{
        .{ .name = "Tank", .stats = tank_stats, .profile = &profile_all_damage },
        .{ .name = "Medic", .stats = support_stats, .profile = &profile_all_heal },
        .{ .name = "Cannon", .stats = cannon_stats, .profile = &profile_all_damage },
    },
};
