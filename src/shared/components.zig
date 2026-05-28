//! All ECS component types shared between client and server.
//!
//! Component identity is determined by comptime index in the World(...)
//! instantiation, so this file is the single source of truth for both.
//! Neither client nor server may define additional game-state components
//! outside this file.
//!
//! ## Combo slot model
//!
//! A combo is a sequence of up to MAX_COMBO_LEN `ComboSlot` values.
//! Each slot is either an `ActionChoice` (damage/shield/heal) or an
//! `Element` modifier (fire/earth/wind/water).  An element token applies
//! to all following action tokens until the next element token or end of
//! combo.  Trailing element tokens with no following action are ignored
//! during resolution.  See `game_logic.parse_combo` for the canonical
//! interpretation.
//!
//! ## Elemental shields
//!
//! Shield actions cancel matching-element damage actions within the same round.
//! `ElementKey` and `element_key` index the 5-bucket tally arrays used during
//! round resolution.  Shields do not persist between rounds; unused cancellation
//! capacity is silently discarded.

const std = @import("std");

pub const Health = struct {
    current: u16,
    max: u16,
};

pub const ClassTag = enum(u8) {
    fighter = 0,
    mage = 1,
    healer = 2,
    grunt = 3,
    archer = 4,
    shaman = 5,
    boss = 6,
};

pub const Class = struct {
    tag: ClassTag,
};

pub const TeamId = enum(u8) {
    players = 0,
    enemies = 1,
};

pub const Team = struct {
    id: TeamId,
};

/// Zero-size marker component. Present only on player-team entities.
/// Distinguishes the PlayerTeam system signature from EnemyTeam.
pub const PlayerMarker = struct {};

/// Zero-size marker component. Present only on enemy-team entities.
/// Distinguishes the EnemyTeam system signature from PlayerTeam.
pub const EnemyMarker = struct {};

pub const Owner = struct {
    player_id: u8,
};

pub const ActionChoice = enum(u8) {
    damage = 0,
    shield = 1,
    heal = 2,

    pub const size = @typeInfo(ElementKey).@"enum".fields.len;
};

/// Elemental modifier applied to following action slots in a combo.
pub const Element = enum(u8) {
    fire = 0,
    earth = 1,
    wind = 2,
    water = 3,

    pub const size = @typeInfo(ElementKey).@"enum".fields.len;
};

/// Array index for elemental shield buckets.  `none` covers non-elemental
/// actions; the four element variants map 1-to-1 from `Element` ordinal + 1.
pub const ElementKey = enum(u8) {
    none = 0,
    fire = 1,
    earth = 2,
    wind = 3,
    water = 4,

    pub const size = @typeInfo(ElementKey).@"enum".fields.len;
};

/// Map an optional Element to the corresponding ElementKey bucket index.
pub fn element_key(e: ?Element) ElementKey {
    return if (e) |el| @enumFromInt(@intFromEnum(el) + 1) else .none;
}

/// One slot in a combo: either an action or an element modifier.
/// Wire encoding: action = raw ActionChoice value (0x00–0x02);
///                element = 0x80 | raw Element value (0x80–0x83).
pub const ComboSlot = union(enum) {
    action: ActionChoice,
    element: Element,
};

pub const MAX_COMBO_LEN: u8 = 4;

/// An ordered sequence of 1–MAX_COMBO_LEN combo slots submitted by a player
/// for one round.  Slots are action tokens (damage/shield/heal) optionally
/// preceded by element modifier tokens.  See `game_logic.parse_combo` for
/// the resolution rules.
pub const ActionCombo = struct {
    slots: [MAX_COMBO_LEN]ComboSlot,
    len: u8, // 1..MAX_COMBO_LEN
};

/// Animation to play on an entity, signalled by the server via action_result
/// and forwarded to the browser in the render JSON.  Extend by adding variants.
pub const ActionAnimation = enum(u8) {
    attack = 0,
    hurt = 1,
    die = 2,
};
