//! Balance configuration — the single place to tune combat feel.
//!
//! ## Structure
//!
//!   ActionValues   — base per-action-type multipliers (the "basic" preset)
//!   ComboTrigger   — table of special combo patterns; replaces the hardcoded
//!                    detect_dot_triggers / detect_cleanse_triggers logic
//!   EnemyPattern   — named enemy combo templates
//!   enemy_sequences — per-element round-robin indices into enemy_patterns
//!   FormulaCtx     — context struct passed to scale_* functions
//!   scale_*        — edit these to experiment with different scaling models
//!
//! ## How scaling works
//!
//!   Normal actions (damage/shield/heal that do NOT match a trigger pattern):
//!     contribution = scale_damage/shield/heal(ctx)  — called once per action
//!     ctx is built from the submitting player's (or enemy's) Statblock.
//!
//!   DoT stack placement (when a trigger fires and survives the shield gate):
//!     stacks_added = scale_dot_stacks(ctx)  — ctx.base = trigger.dot_stacks_base
//!     The number of stacks placed varies with the caster's stats.
//!
//!   DoT tick damage (every round a stack exists):
//!     damage = stack_count * basic.dot_tick  — flat, no per-player variance.

const c = @import("components.zig");

// ── 1. Base action values ─────────────────────────────────────────────────

pub const ActionValues = struct {
    /// Damage dealt per damage action (before stat scaling).
    damage: u16,
    /// Damage absorbed per shield action (before stat scaling).
    shield: u16,
    /// HP restored per heal action (before stat scaling).
    heal: u16,
    /// Flat damage per DoT stack per round (no stat scaling at tick time).
    dot_tick: u16,
};

/// The default preset.  All values are 1 so the game plays like the original
/// flat-count system until you start editing formulas or stats.
pub const basic = ActionValues{
    .damage = 1,
    .shield = 1,
    .heal = 1,
    .dot_tick = 1,
};

// ── 2. Combo trigger definitions ──────────────────────────────────────────

pub const TriggerKind = enum { dot, cleanse };

/// A special combo pattern.  A trigger fires when one elemental group in a
/// combo contains **exactly** `damage` damage actions, `shield` shield actions,
/// and `heal` heal actions — no others.  Null-element groups never trigger.
///
/// When fired:
///   - Actions flagged `withheld_*` are removed from normal pool contribution.
///   - For dot triggers: `scale_dot_stacks(ctx)` stacks (base = dot_stacks_base)
///     are placed on the opponent's DoT array if the withheld damage survives
///     the opponent's shields (Step 3 peek-net in session.resolve_round).
///   - For cleanse triggers: `cleanse_stacks_removed` stacks are removed from
///     own side's DoT array unconditionally (Step 2.5).
pub const ComboTrigger = struct {
    kind: TriggerKind,
    /// Exact action counts required in a single elemental group to match.
    damage: u8,
    shield: u8,
    heal: u8,
    /// Which action types are consumed (not counted in normal pools) when this
    /// trigger matches.  Independent per type — set what makes sense per recipe.
    withheld_damage: bool,
    withheld_shield: bool,
    withheld_heal: bool,
    /// Base stacks added to the opponent on a successful DoT trigger.
    /// Passed as `ctx.base` to `scale_dot_stacks`.  Ignored for cleanse.
    dot_stacks_base: u16,
    /// Stacks unconditionally removed from own side on a cleanse trigger.
    cleanse_stacks_removed: u16,
};

/// The active trigger table.  Add, remove, or edit rows to change what special
/// combos exist.  Order does not matter; all triggers are evaluated per combo.
pub const combo_triggers = [_]ComboTrigger{
    // DoT: [element, damage, heal]  →  +dot_stacks on opponent; dmg+heal withheld.
    .{
        .kind = .dot,
        .damage = 1,
        .shield = 0,
        .heal = 1,
        .withheld_damage = true,
        .withheld_shield = false,
        .withheld_heal = true,
        .dot_stacks_base = 1,
        .cleanse_stacks_removed = 0,
    },
    // Cleanse: [element, heal, shield]  →  remove 1 own stack; heal+shield withheld.
    .{
        .kind = .cleanse,
        .damage = 0,
        .shield = 1,
        .heal = 1,
        .withheld_damage = false,
        .withheld_shield = true,
        .withheld_heal = true,
        .dot_stacks_base = 0,
        .cleanse_stacks_removed = 1,
    },
};

// ── 3. Enemy AI patterns ──────────────────────────────────────────────────

pub const EnemyPattern = struct {
    label: []const u8,
    slots: [c.MAX_COMBO_LEN]c.ComboSlot,
    len: u8,
};
pub const enemy_patterns = [_]EnemyPattern{
    .{
        .label = "fire_dot",
        .slots = .{
            .{ .element = .fire },
            .{ .action = .damage },
            .{ .action = .heal },
            .{ .action = .damage },
        },
        .len = 3,
    },
    .{
        .label = "fire_cleanse",
        .slots = .{
            .{ .element = .fire },
            .{ .action = .heal },
            .{ .action = .shield },
            .{ .action = .damage },
        },
        .len = 3,
    },
    .{
        .label = "fire_attack",
        .slots = .{
            .{ .element = .fire },
            .{ .action = .damage },
            .{ .action = .damage },
            .{ .action = .damage },
        },
    },
    .{
        .label = "big_heal",
        .slots = .{
            .{ .element = .wind },
            .{ .action = .heal },
            .{ .action = .heal },
            .{ .action = .heal },
            .{ .action = .heal },
            //
        },
    },
};

/// Per-element round sequences.  Indexed by `@intFromEnum(Element)`:
///   [0] = fire, [1] = earth, [2] = wind, [3] = water.
///
/// Each entry is a slice of indices into `enemy_patterns`.  The pattern used
/// in round N is `enemy_patterns[ seq[round_count % seq.len] ]`.
///
/// Enemies without an assigned element (null-element) use index 0 (fire).
/// Each element can have a completely different rotation — add patterns and
/// edit these arrays to differentiate enemy types.
pub const enemy_sequences = [c.Element.size][]const u8{
    &[_]u8{ 0, 1, 2, 3 },
    &[_]u8{0},
    &[_]u8{0},
    &[_]u8{0},
};

// ── 4. Stat-scaling formulas ──────────────────────────────────────────────

/// Context built from the submitting entity's Statblock for one action.
/// Passed to every `scale_*` function.
pub const FormulaCtx = struct {
    /// Base value from ActionValues (damage / shield / heal / dot_stacks_base).
    base: u16,
    attack: u16,
    shield_stat: u16,
    heal_stat: u16,
    /// The statblock field corresponding to the action's element
    /// (sb.fire / .earth / .wind / .water), or 0 for null-element actions.
    element_stat: u16,
    level: u16,
};

/// Damage contributed by one damage action from an entity with this context.
pub fn scale_damage(ctx: FormulaCtx) u16 {
    return ctx.base * @max(1, ctx.attack);
}

/// Absorb contributed by one shield action.
pub fn scale_shield(ctx: FormulaCtx) u16 {
    return ctx.base * @max(1, ctx.shield_stat);
}

/// Healing contributed by one heal action.
pub fn scale_heal(ctx: FormulaCtx) u16 {
    return ctx.base * @max(1, ctx.heal_stat);
}

/// Stacks placed on the opponent when a DoT trigger fires and clears shields.
/// ctx.base = trigger.dot_stacks_base.
pub fn scale_dot_stacks(ctx: FormulaCtx) u16 {
    _ = ctx.element_stat; // available for future formulas
    return ctx.base * @max(1, ctx.attack);
}
