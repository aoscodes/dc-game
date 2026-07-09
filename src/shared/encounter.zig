//! Encounter definitions: the slime field layout for one game.
//!
//! An encounter is an ordered list of zones.  Round N consumes zone N in its
//! entirety; the encounter ends when every zone is consumed or the hunger
//! bar fills.  One encounter per game (no chaining).
//!
//! Amounts/types of slime per zone and the hunger budget are the primary
//! difficulty tuning knobs — TODO tune with playtesting.

const std = @import("std");
const c = @import("components.zig");

/// Upper bound on zones per encounter (wire + session array sizing).
pub const MAX_ZONES: u8 = 8;

pub const Encounter = struct {
    label: []const u8,
    /// Hunger bar capacity; encounter ends when reached.
    hunger_max: u16,
    zones: []const c.ZoneDef,
};

/// Default 3-zone encounter.  Totals: 110 units → 110 normal hunger; fully
/// un-neutralized modified slime adds 160 extra → 270 (fail without play);
/// full neutralization keeps it at 110 (comfortable clear).  TODO tune.
pub const encounter_01 = Encounter{
    .label = "slime_feast_01",
    .hunger_max = 200,
    .zones = &[_]c.ZoneDef{
        .{ .modified = .{ 10, 5, 0, 0 }, .neutral = 15 },
        .{ .modified = .{ 10, 10, 5, 0 }, .neutral = 10 },
        .{ .modified = .{ 15, 10, 10, 5 }, .neutral = 5 },
    },
};

pub const EncounterEntry = struct {
    label: []const u8,
    encounter: *const Encounter,
};

pub const ALL_ENCOUNTERS = [_]EncounterEntry{
    .{ .label = encounter_01.label, .encounter = &encounter_01 },
};

pub const DEFAULT_ENCOUNTER = &encounter_01;

pub fn find_encounter(label: []const u8) ?*const Encounter {
    for (&ALL_ENCOUNTERS) |entry| {
        if (std.mem.eql(u8, entry.label, label)) return entry.encounter;
    }
    return null;
}

test "encounter zones fit session/wire bounds" {
    for (&ALL_ENCOUNTERS) |entry| {
        try std.testing.expect(entry.encounter.zones.len >= 1);
        try std.testing.expect(entry.encounter.zones.len <= MAX_ZONES);
    }
}
