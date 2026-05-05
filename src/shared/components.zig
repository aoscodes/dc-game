//! All ECS component types shared between client and server.
//!
//! Component identity is determined by comptime index in the World(...)
//! instantiation, so this file is the single source of truth for both.
//! Neither client nor server may define additional game-state components
//! outside this file.

pub const Health = struct {
    current: u16,
    max: u16,
};

pub const Shield = struct {
    hp: u16,
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
};

pub const MAX_COMBO_LEN: u8 = 4;

/// An ordered sequence of 1–4 actions submitted by a player for one round.
/// Every slot in `actions[0..len]` contributes independently to the shared
/// action pools when the round resolves.
pub const ActionCombo = struct {
    actions: [MAX_COMBO_LEN]ActionChoice,
    len: u8, // 1..MAX_COMBO_LEN
};

/// Animation to play on an entity, signalled by the server via action_result
/// and forwarded to the browser in the render JSON.  Extend by adding variants.
pub const ActionAnimation = enum(u8) {
    attack = 0,
    hurt = 1,
    die = 2,
};
