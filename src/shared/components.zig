//! All ECS component types shared between client and server.
//!
//! Component identity is determined by comptime index in the World(...)
//! instantiation, so this file is the single source of truth for both.
//! Neither client nor server may define additional game-state components
//! outside this file.

// ---------------------------------------------------------------------------
// Grid
// ---------------------------------------------------------------------------

/// Position on a 3-column × 4-row grid.
///
/// Columns 0–2 (left→right), rows 0–3 (front→back).
/// Row 0 = Front Rank, Row 1 = Mid Rank, Row 2 = Back Rank.
/// Row 3 is reserved for large/boss enemies that occupy the full back.
pub const GridPos = struct {
    col: u2, // 0–2
    row: u2, // 0–3
};

// ---------------------------------------------------------------------------
// Vitals
// ---------------------------------------------------------------------------

pub const Health = struct {
    current: u16,
    max: u16,
};

/// Active Time Battle gauge.
///
/// `gauge` ticks from 0.0 → 1.0 at `rate` units/second (server-driven).
/// When `gauge >= 1.0` the entity enters `ActionState.charging`.
pub const Speed = struct {
    gauge: f32 = 0.0,
    /// Ticks per second; derived from Stats.speed_base at spawn time.
    rate: f32,
};

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

pub const ClassTag = enum(u8) {
    // Player classes
    fighter = 0,
    mage = 1,
    healer = 2,
    // Enemy classes
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

/// Which connected client controls this character.
/// Only meaningful for player-team entities.
/// `player_id` matches the u8 assigned at lobby join.
pub const Owner = struct {
    player_id: u8,
};

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

/// Base stats; do not change during a battle (use ActiveEffect for temporary
/// modifiers). Derived display values (e.g. HP) live in Health/Speed.
pub const Stats = struct {
    attack: u16,
    defense: u16,
    speed_base: f32,
    max_hp: u16,
};

// ---------------------------------------------------------------------------
// Action state
// ---------------------------------------------------------------------------

pub const ActionStateTag = enum(u8) {
    idle = 0, // ATB filling
    charging = 1, // ATB full; waiting for player input (or AI decision)
    acting = 2, // action in flight (brief window; server resolves)
    defending = 3, // committed to defend stance; persists until next turn
};

pub const ActionState = struct {
    tag: ActionStateTag = .idle,
};

// ---------------------------------------------------------------------------
// Active effects
// ---------------------------------------------------------------------------

pub const EffectTag = enum(u8) {
    /// Reduces incoming damage by `magnitude` fraction (0.0–1.0).
    mitigation = 0,
};

/// A single temporary effect on an entity.
/// Multiple effects stack additively (server sums all mitigation magnitudes,
/// capped at MAX_MITIGATION).
pub const ActiveEffect = struct {
    tag: EffectTag,
    /// Remaining duration in seconds; server decrements each tick.
    duration: f32,
    /// Effect-specific scalar. For mitigation: fraction (e.g. 0.30 = 30%).
    magnitude: f32,
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Maximum summed mitigation fraction applied to any single damage hit.
pub const MAX_MITIGATION: f32 = 0.75;

/// Fighter defend: protects entities in `(col, row+1)` through `(col, row+3)`.
/// This is the 1×3 projection directly behind the fighter on the same column.
pub const FIGHTER_DEFEND_DEPTH: u2 = 3;

/// AoE radius for mage attacks and healer heals (2×2 region on their grid).
pub const AOE_SIZE: u2 = 2;

/// Mitigation magnitude granted by a defend action.
pub const DEFEND_MITIGATION: f32 = 0.30;

/// How long a defend effect persists (seconds); covers roughly one ATB cycle
/// for a mid-speed character.
pub const DEFEND_DURATION_S: f32 = 4.0;
