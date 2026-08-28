//! Encounter *types*: the slime supply for one game.
//!
//! An encounter is a CHARGE budget and the TOTAL slime the Lil Guys will
//! eat.  That slime starts in the off-grid reservoir; the grid (dimensions
//! come from balance.slime_grid, a global knob) is filled from it and
//! refilled from the top as cells are emptied.  The encounter ends when
//! every playable unit is eaten, the hunger bar fills, or the charges run out
//! with the field still walled off.  One encounter per game (no chaining).
//!
//! The hunger bar's CAPACITY is not an encounter knob any more: it is the sum
//! of every player's appetite-derived contribution (balance.hunger_base /
//! appetite_scale / hunger_player_cap — see game_logic.player_hunger), so a
//! bigger or hungrier team gets a bigger bar.
//!
//! There is exactly ONE slime field per game — the old multi-zone/per-round
//! split is gone.  `data/encounters.json` still lists slime in `zones` for
//! back-compatibility with saved designer configs; config.zig SUMS those
//! entries into the single `slime` total (see parse_encounters).
//!
//! The actual encounters live in `data/encounters.json` and are loaded at
//! server start by `config.zig` — the slime mix and the hunger budget are the
//! primary difficulty tuning knobs.

const std = @import("std");
const c = @import("components.zig");

/// Upper bound on `zones` entries accepted in one encounter document.  The
/// entries are summed into a single slime total, so this only bounds parsing
/// of legacy configs.
pub const MAX_ZONES: u8 = 16;

/// Wire cap on the encounter label (GameStart message field).
pub const MAX_LABEL_LEN: u8 = 32;

/// Charges an encounter grants when `charges` is absent from its JSON entry.
pub const DEFAULT_CHARGES: u32 = 30;

pub const Encounter = struct {
    label: []const u8,
    /// Charges the team starts with, shared by everyone and spent across the
    /// WHOLE encounter — never refilled between turns.  This is the encounter's
    /// sharpest difficulty knob: it caps the total number of walls the team can
    /// ever open, so it decides how much of the field is reachable at all.
    /// Validated > 0: a team that cannot cast cannot play.
    charges: u32 = DEFAULT_CHARGES,
    /// All the slime in this encounter, as the reservoir starts it.
    slime: c.SlimeReservoir,

    /// Total slime units in this encounter.
    pub fn total_units(self: *const Encounter) u32 {
        return self.slime.total();
    }
};

/// The loaded encounter table plus which entry is the default.
pub const EncounterSet = struct {
    encounters: []const Encounter,
    /// Index into `encounters` of the default encounter (validated on load).
    default_index: usize,

    pub fn default(self: *const EncounterSet) *const Encounter {
        return &self.encounters[self.default_index];
    }

    pub fn find(self: *const EncounterSet, label: []const u8) ?*const Encounter {
        for (self.encounters) |*e| {
            if (std.mem.eql(u8, e.label, label)) return e;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Encounter total_units sums every slime bucket, specials included" {
    var slime = c.SlimeReservoir{ .neutral = 5, .special = .{ 2, 1, 0, 0, 0 } };
    slime.tiered[@intFromEnum(c.Tier.red)] = 10;
    slime.tiered[@intFromEnum(c.Tier.green)] = 3;
    const e = Encounter{ .label = "t", .slime = slime };
    // Specials of every kind occupy grid cells, so they are part of the
    // supply — even the neutralizers, which are never eaten.
    try testing.expectEqual(@as(u32, 21), e.total_units());
}

test "EncounterSet default and find resolve by label" {
    const list = [_]Encounter{
        .{ .label = "a", .slime = .{ .neutral = 1 } },
        .{ .label = "b", .slime = .{ .neutral = 2 } },
    };
    const set = EncounterSet{ .encounters = &list, .default_index = 1 };
    try testing.expectEqualStrings("b", set.default().label);
    try testing.expectEqualStrings("a", set.find("a").?.label);
    try testing.expectEqual(@as(?*const Encounter, null), set.find("nope"));
}
