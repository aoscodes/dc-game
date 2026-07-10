//! Encounter *types*: the slime field layout for one game.
//!
//! An encounter is an ordered list of zones.  Round N consumes zone N in its
//! entirety; the encounter ends when every zone is consumed or the hunger
//! bar fills.  One encounter per game (no chaining).
//!
//! The actual encounters live in `data/encounters.json` and are loaded at
//! server start by `config.zig` — amounts/types of slime per zone and the
//! hunger budget are the primary difficulty tuning knobs.

const std = @import("std");
const c = @import("components.zig");

/// Upper bound on zones per encounter (wire + session array sizing).
/// The config loader rejects encounters exceeding it.
pub const MAX_ZONES: u8 = 16;

/// Wire cap on the encounter label (GameStart message field).
pub const MAX_LABEL_LEN: u8 = 32;

pub const Encounter = struct {
    label: []const u8,
    /// Hunger bar capacity; encounter ends when reached.
    hunger_max: u16,
    zones: []const c.ZoneDef,
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
