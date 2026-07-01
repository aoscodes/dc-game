const c = @import("components.zig");

pub const ActionValues = struct {
    damage: u16,
    shield: u16,
    heal: u16,
    dot_tick: u16,
};

pub const basic = ActionValues{
    .damage = 1,
    .shield = 1,
    .heal = 1,
    .dot_tick = 1,
};

pub const TriggerKind = enum { dot, cleanse };

pub const ComboTrigger = struct {
    kind: TriggerKind,
    damage: u8,
    shield: u8,
    heal: u8,
    withheld_damage: bool,
    withheld_shield: bool,
    withheld_heal: bool,
    dot_stacks_base: u16,
    cleanse_stacks_removed: u16,
};

pub const combo_triggers = [_]ComboTrigger{
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
        .len = 3,
    },
    .{
        .label = "big_heal",
        .slots = .{
            .{ .element = .wind },
            .{ .action = .heal },
            .{ .action = .heal },
            .{ .action = .heal },
        },
        .len = 3,
    },
};

pub const enemy_sequences = [c.Element.size][]const u8{
    &[_]u8{ 0, 1, 2, 3 },
    &[_]u8{0},
    &[_]u8{0},
    &[_]u8{0},
};

pub const FormulaCtx = struct {
    base: u16,
    attack: u16,
    shield_stat: u16,
    heal_stat: u16,
    element_stat: u16,
    level: u16,
};

pub fn scale_damage(ctx: FormulaCtx) u16 {
    return ctx.base * @max(1, ctx.attack);
}

pub fn scale_shield(ctx: FormulaCtx) u16 {
    return ctx.base * @max(1, ctx.shield_stat);
}

pub fn scale_heal(ctx: FormulaCtx) u16 {
    return ctx.base * @max(1, ctx.heal_stat);
}

pub fn scale_dot_stacks(ctx: FormulaCtx) u16 {
    _ = ctx.element_stat; // available for future formulas
    return ctx.base * @max(1, ctx.attack);
}
