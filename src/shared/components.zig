//! All ECS component types shared between client and server.
//!
//! Component identity is determined by comptime index in the World(...)
//! instantiation, so this file is the single source of truth for both.
//! Neither client nor server may define additional game-state components
//! outside this file.
//!
//! ## Slime Feast model
//!
//! Players support a horde of cosmetic "Lil Guys" that devour a slime field
//! split into zones.  Each round the current zone is consumed in its
//! entirety.  Modified Slime (colored, per-Element) costs extra hunger
//! unless players neutralize it first by dispensing matching-color
//! Neutralizing Agents.  Medicine heals the hunger bar, but only the
//! portion attributable to modified-slime consumption.
//!
//! ## Combo slot model
//!
//! A combo is a sequence of up to MAX_COMBO_LEN `ComboSlot` values.
//! Each slot is either an `ActionChoice` (dispense/medicine) or an
//! `Element` modifier (red/green/yellow/blue — the four agent colors).
//! An element token applies to all following action tokens until the next
//! element token or end of combo.  Trailing element tokens with no
//! following action are ignored during resolution.  See
//! `game_logic.parse_combo` for the canonical interpretation.
//!
//! Exact combos may match recipes (player/team tables loaded from
//! data/balance.json — see config.zig) which *replace* the combo's flat
//! per-slot conversion with a tuned AgentOutput.

const std = @import("std");

pub const Health = struct {
    current: u16,
    max: u16,
};

/// Kind of entity on the wire.  Only players exist server-side; the browser
/// renders cosmetic Lil Guys/slime itself.  Extend when new server-side
/// entity kinds appear.
pub const EntityKind = enum(u8) {
    player = 0,
};

pub const Kind = struct {
    tag: EntityKind,
};

/// Zero-size marker component. Present on every player entity; drives the
/// PlayerTeam system signature.
pub const PlayerMarker = struct {};

pub const Owner = struct {
    player_id: u8,
};

/// Player actions:
///   dispense — release Neutralizing Agent units of the current combo element
///              (agent color) onto the current round's zone.
///   medicine — contribute to the round's medicine pool OF THE CURRENT combo
///              element.  Medicine is symmetrical: color-X medicine heals
///              only the hunger caused by eating un-neutralized color-X
///              Modified Slime.  Colorless medicine is wasted.
pub const ActionChoice = enum(u8) {
    dispense = 0,
    medicine = 1,

    pub const size = @typeInfo(ActionChoice).@"enum".fields.len;
};

/// Agent color / Modified Slime type.  Reskinned elements: the color of a
/// slime communicates which Neutralizing Agent it requires.
pub const Element = enum(u8) {
    red = 0,
    green = 1,
    yellow = 2,
    blue = 3,

    pub const size = @typeInfo(Element).@"enum".fields.len;
};

/// One slot in a combo: either an action or an element modifier.
/// Wire encoding: action = raw ActionChoice value (0x00–0x01);
///                element = 0x80 | raw Element value (0x80–0x83).
pub const ComboSlot = union(enum) {
    action: ActionChoice,
    element: Element,
};

pub const MAX_COMBO_LEN: u8 = 5;

/// An ordered sequence of 1–MAX_COMBO_LEN combo slots submitted by a player
/// for one round.  Slots are action tokens (dispense/medicine) optionally
/// preceded by element modifier tokens.  See `game_logic.parse_combo` for
/// the resolution rules.
pub const ActionCombo = struct {
    slots: [MAX_COMBO_LEN]ComboSlot,
    len: u8, // 1..MAX_COMBO_LEN
};

/// Build an ActionCombo from a slice of slots (must be 1..MAX_COMBO_LEN).
/// Unused trailing slots are padded with a harmless dispense action.
pub fn make_combo(slots: []const ComboSlot) ActionCombo {
    std.debug.assert(slots.len >= 1 and slots.len <= MAX_COMBO_LEN);
    var combo = ActionCombo{
        .slots = [_]ComboSlot{.{ .action = .dispense }} ** MAX_COMBO_LEN,
        .len = @intCast(slots.len),
    };
    @memcpy(combo.slots[0..slots.len], slots);
    return combo;
}

/// One zone of the slime field.  `modified[e]` = units of Modified Slime of
/// color `e` (Element ordinal); `neutralized[e]` = modified units transmuted
/// by Neutralizing Agents (tracked per original color, consumed at normal
/// cost); `neutral` = units of naturally-neutral slime.  Transmutation
/// happens per cast window; the entire zone is consumed at the end of its
/// round.
pub const ZoneDef = struct {
    modified: [Element.size]u16 = [_]u16{0} ** Element.size,
    neutralized: [Element.size]u16 = [_]u16{0} ** Element.size,
    neutral: u16 = 0,

    pub fn total_units(self: ZoneDef) u32 {
        var total: u32 = self.neutral;
        for (self.modified) |m| total += m;
        for (self.neutralized) |n| total += n;
        return total;
    }
};

/// Result of converting one round's combos: Neutralizing Agent units and
/// medicine pools, both per color.  Color-X medicine heals only the healable
/// hunger caused by color-X modified slime (symmetrical healing).  Produced
/// per-combo (flat conversion or recipe output) and summed across the team.
pub const AgentOutput = struct {
    units: [Element.size]u32 = [_]u32{0} ** Element.size,
    medicine: [Element.size]u32 = [_]u32{0} ** Element.size,

    pub fn add(self: *AgentOutput, other: AgentOutput) void {
        for (&self.units, other.units) |*u, o| u.* +|= o;
        for (&self.medicine, other.medicine) |*m, o| m.* +|= o;
    }
};

/// Animation to play on an entity, signalled by the server via action_result
/// and forwarded to the browser in the render JSON.  Extend by adding variants.
pub const ActionAnimation = enum(u8) {
    attack = 0,
    hurt = 1,
    die = 2,
};
