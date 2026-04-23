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

pub const Owner = struct {
    player_id: u8,
};

pub const Stats = struct {
    attack: u16,
    defense: u16,
    speed_base: f32,
    max_hp: u16,
};

/// The action a player chooses to contribute to the shared pool each round.
pub const ActionChoice = enum(u8) {
    damage = 0,
    shield = 1,
    heal = 2,
};
