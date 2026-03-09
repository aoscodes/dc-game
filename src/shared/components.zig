//! All ECS component types shared between client and server.
//!
//! Component identity is determined by comptime index in the World(...)
//! instantiation, so this file is the single source of truth for both.
//! Neither client nor server may define additional game-state components
//! outside this file.

pub const GridPos = struct {
    col: u2, // 0–2
    row: u2, // 0–3
};

pub const Health = struct {
    current: u16,
    max: u16,
};

pub const Speed = struct {
    gauge: f32 = 0.0,
    rate: f32,
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

pub const ActionStateTag = enum(u8) {
    idle = 0, // ATB filling
    charging = 1, // ATB full; waiting for player input (or AI decision)
    acting = 2, // action in flight (brief window; server resolves)
    defending = 3, // committed to defend stance; persists until next turn
};

pub const ActionState = struct {
    tag: ActionStateTag = .idle,
};

pub const EffectTag = enum(u8) {
    mitigation = 0,
};

pub const ActiveEffect = struct {
    tag: EffectTag,
    duration: f32,
    magnitude: f32,
};

pub const MAX_MITIGATION: f32 = 0.75;

pub const FIGHTER_DEFEND_DEPTH: u2 = 3;

pub const AOE_SIZE: u2 = 2;

pub const DEFEND_MITIGATION: f32 = 0.30;

pub const DEFEND_DURATION_S: f32 = 4.0;
