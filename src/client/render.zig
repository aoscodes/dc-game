const rl = @import("raylib");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;
const input = @import("input.zig");

pub const SW: f32 = 1024;
pub const SH: f32 = 768;

const CELL_W: f32 = 90;
const CELL_H: f32 = 100;
const CELL_PAD: f32 = 6;

const PLAYER_GRID_X: f32 = 60;
const PLAYER_GRID_Y: f32 = 180;

const ENEMY_GRID_X: f32 = SW - 60 - (CELL_W + CELL_PAD) * 3;
const ENEMY_GRID_Y: f32 = 180;

fn class_color(class: c.ClassTag) rl.Color {
    return switch (class) {
        .fighter => .{ .r = 60, .g = 120, .b = 200, .a = 220 },
        .mage => .{ .r = 180, .g = 60, .b = 200, .a = 220 },
        .healer => .{ .r = 60, .g = 200, .b = 120, .a = 220 },
        .grunt => .{ .r = 160, .g = 80, .b = 40, .a = 220 },
        .archer => .{ .r = 140, .g = 160, .b = 40, .a = 220 },
        .shaman => .{ .r = 200, .g = 100, .b = 60, .a = 220 },
        .boss => .{ .r = 200, .g = 20, .b = 20, .a = 255 },
    };
}

const COLOR_BG = rl.Color{ .r = 20, .g = 20, .b = 30, .a = 255 };
const COLOR_CELL_EMPTY = rl.Color{ .r = 40, .g = 40, .b = 55, .a = 180 };
const COLOR_ATB_BG = rl.Color{ .r = 30, .g = 30, .b = 30, .a = 200 };
const COLOR_ATB_FILL = rl.Color{ .r = 255, .g = 220, .b = 50, .a = 230 };
const COLOR_HP_BG = rl.Color{ .r = 30, .g = 10, .b = 10, .a = 200 };
const COLOR_HP_FILL = rl.Color{ .r = 60, .g = 200, .b = 60, .a = 230 };
const COLOR_CURSOR = rl.Color{ .r = 255, .g = 255, .b = 100, .a = 180 };
const COLOR_CHARGING = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 60 };
const COLOR_MITIGATED = rl.Color{ .r = 80, .g = 120, .b = 255, .a = 80 };
const COLOR_TEXT = rl.Color{ .r = 230, .g = 230, .b = 230, .a = 255 };
const COLOR_HEADER = rl.Color{ .r = 180, .g = 200, .b = 255, .a = 255 };

pub const SceneTag = enum { lobby, game };

pub const LobbyState = struct {
    update: proto.LobbyUpdate = std.mem.zeroes(proto.LobbyUpdate),
    our_player_id: u8 = 0xFF,
    selected_class: c.ClassTag = .fighter,
    ready: bool = false,
    error_msg: [64]u8 = [_]u8{0} ** 64,
    error_msg_len: u8 = 0,
};

pub const GameState = struct {
    snapshot: proto.GameState = std.mem.zeroes(proto.GameState),
    our_player_id: u8 = 0xFF,
    our_entity: u32 = std.math.maxInt(u32),
    cursor: input.InputState = .{},
    targeting_enemy: bool = true,
    action_selected: ?proto.ActionTag = null,
    wave_label: [32]u8 = [_]u8{0} ** 32,
    wave_label_len: u8 = 0,
};

pub fn draw_lobby(state: *const LobbyState) void {
    rl.clearBackground(COLOR_BG);

    rl.drawText("JRPG  —  Lobby", 40, 30, 32, COLOR_HEADER);

    {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "Room: {s}", .{state.update.join_code}) catch "Room: ??????";
        rl.drawText(s, 40, 80, 22, COLOR_TEXT);
    }

    const list_y: i32 = 130;
    {
        var i: u8 = 0;
        while (i < state.update.player_count) : (i += 1) {
            const p = state.update.players[i];
            const y = list_y + @as(i32, i) * 36;
            const color: rl.Color = if (p.player_id == state.our_player_id)
                .{ .r = 255, .g = 255, .b = 100, .a = 255 }
            else
                COLOR_TEXT;

            var buf: [80]u8 = undefined;
            const name = p.name[0..p.name_len];
            const ready_str: []const u8 = if (p.ready) "[READY]" else "[      ]";
            const conn_str: []const u8 = if (p.connected) "" else " (disconnected)";
            const s = std.fmt.bufPrintZ(
                &buf,
                "{s}  {s}  {s}{s}",
                .{ name, @tagName(p.class), ready_str, conn_str },
            ) catch "?";
            rl.drawText(s, 60, y, 20, color);
        }
    }

    {
        const picker_y: i32 = list_y + @as(i32, proto.MAX_PLAYERS) * 36 + 20;
        rl.drawText("Class:  [1] Fighter   [2] Mage   [3] Healer", 60, picker_y, 18, COLOR_TEXT);

        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "Selected: {s}", .{@tagName(state.selected_class)}) catch "?";
        rl.drawText(s, 60, picker_y + 28, 18, COLOR_HEADER);

        const ready_label: [:0]const u8 = if (state.ready) "Press ENTER to un-ready" else "Press ENTER when ready";
        rl.drawText(ready_label, 60, picker_y + 60, 18, COLOR_TEXT);
    }

    if (state.error_msg_len > 0) {
        var buf: [80]u8 = undefined;
        const err_s = std.fmt.bufPrintZ(&buf, "{s}", .{state.error_msg[0..state.error_msg_len]}) catch "error";
        rl.drawText(err_s, 60, @intFromFloat(SH - 40), 18, .{ .r = 255, .g = 80, .b = 80, .a = 255 });
    }
}

pub fn draw_game(state: *const GameState) void {
    rl.clearBackground(COLOR_BG);

    {
        var buf: [48]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "Wave: {s}", .{
            state.wave_label[0..state.wave_label_len],
        }) catch "Wave: ?";
        rl.drawText(s, 40, 20, 20, COLOR_HEADER);
    }

    rl.drawText("ALLIES", @intFromFloat(PLAYER_GRID_X), 155, 18, COLOR_HEADER);
    rl.drawText("ENEMIES", @intFromFloat(ENEMY_GRID_X), 155, 18, .{ .r = 255, .g = 120, .b = 80, .a = 255 });

    draw_grid(state, .players, PLAYER_GRID_X, PLAYER_GRID_Y);
    draw_grid(state, .enemies, ENEMY_GRID_X, ENEMY_GRID_Y);

    if (state.cursor.is_our_turn) {
        draw_action_menu(state);
    }
}

fn draw_grid(state: *const GameState, team: c.TeamId, ox: f32, oy: f32) void {
    const is_targeting =
        (team == .enemies and state.cursor.is_our_turn and state.targeting_enemy) or
        (team == .players and state.cursor.is_our_turn and !state.targeting_enemy);

    {
        var col: u8 = 0;
        while (col < 3) : (col += 1) {
            var row: u8 = 0;
            while (row < 4) : (row += 1) {
                const cx = ox + @as(f32, @floatFromInt(col)) * (CELL_W + CELL_PAD);
                const cy = oy + @as(f32, @floatFromInt(row)) * (CELL_H + CELL_PAD);
                rl.drawRectangleRec(
                    .{ .x = cx, .y = cy, .width = CELL_W, .height = CELL_H },
                    COLOR_CELL_EMPTY,
                );
            }
        }
    }

    {
        var i: u8 = 0;
        while (i < state.snapshot.entity_count) : (i += 1) {
            const e = state.snapshot.entities[i];
            if (e.team != team) continue;

            const cx = ox + @as(f32, @floatFromInt(e.grid_col)) * (CELL_W + CELL_PAD);
            const cy = oy + @as(f32, @floatFromInt(e.grid_row)) * (CELL_H + CELL_PAD);

            rl.drawRectangleRec(
                .{ .x = cx, .y = cy, .width = CELL_W, .height = CELL_H },
                class_color(e.class),
            );

            if (e.action_state == .charging) {
                rl.drawRectangleRec(
                    .{ .x = cx, .y = cy, .width = CELL_W, .height = CELL_H },
                    COLOR_CHARGING,
                );
            }

            {
                const BAR_H: f32 = 8;
                const frac = if (e.hp_max > 0)
                    @as(f32, @floatFromInt(e.hp_current)) / @as(f32, @floatFromInt(e.hp_max))
                else
                    0.0;
                rl.drawRectangleRec(.{ .x = cx, .y = cy, .width = CELL_W, .height = BAR_H }, COLOR_HP_BG);
                rl.drawRectangleRec(.{ .x = cx, .y = cy, .width = CELL_W * frac, .height = BAR_H }, COLOR_HP_FILL);
            }

            {
                const BAR_H: f32 = 6;
                const atb_y = cy + CELL_H - BAR_H;
                const frac = std.math.clamp(e.atb_gauge, 0.0, 1.0);
                rl.drawRectangleRec(.{ .x = cx, .y = atb_y, .width = CELL_W, .height = BAR_H }, COLOR_ATB_BG);
                rl.drawRectangleRec(.{ .x = cx, .y = atb_y, .width = CELL_W * frac, .height = BAR_H }, COLOR_ATB_FILL);
            }

            {
                const label: [:0]const u8 = switch (e.class) {
                    .fighter => "FTR",
                    .mage => "MGE",
                    .healer => "HLR",
                    .grunt => "GRT",
                    .archer => "ARC",
                    .shaman => "SHA",
                    .boss => "BOSS",
                };
                rl.drawText(label, @intFromFloat(cx + 4), @intFromFloat(cy + 14), 16, COLOR_TEXT);
            }

            {
                var buf: [16]u8 = undefined;
                const s = std.fmt.bufPrintZ(&buf, "{d}", .{e.hp_current}) catch "?";
                rl.drawText(s, @intFromFloat(cx + 4), @intFromFloat(cy + 36), 14, COLOR_TEXT);
            }

            if (e.owner == state.our_player_id and team == .players) {
                rl.drawRectangleLinesEx(
                    .{ .x = cx + 1, .y = cy + 1, .width = CELL_W - 2, .height = CELL_H - 2 },
                    2,
                    .{ .r = 255, .g = 255, .b = 60, .a = 200 },
                );
            }
        }
    }

    if (is_targeting) {
        const cc = state.cursor.cursor_col;
        const cr = state.cursor.cursor_row;
        const cx = ox + @as(f32, @floatFromInt(cc)) * (CELL_W + CELL_PAD);
        const cy = oy + @as(f32, @floatFromInt(cr)) * (CELL_H + CELL_PAD);
        rl.drawRectangleLinesEx(
            .{ .x = cx, .y = cy, .width = CELL_W, .height = CELL_H },
            3,
            COLOR_CURSOR,
        );
    }
}

fn draw_action_menu(state: *const GameState) void {
    const mx: f32 = SW / 2 - 120;
    const my: f32 = SH - 130;
    const mw: f32 = 240;
    const mh: f32 = 110;

    rl.drawRectangleRec(
        .{ .x = mx, .y = my, .width = mw, .height = mh },
        .{ .r = 20, .g = 20, .b = 40, .a = 220 },
    );
    rl.drawRectangleLinesEx(
        .{ .x = mx, .y = my, .width = mw, .height = mh },
        2,
        COLOR_HEADER,
    );

    rl.drawText("Your Turn!", @intFromFloat(mx + 10), @intFromFloat(my + 8), 18, COLOR_HEADER);

    const atk_color: rl.Color = if (state.action_selected == .attack) COLOR_CURSOR else COLOR_TEXT;
    const def_color: rl.Color = if (state.action_selected == .defend) COLOR_CURSOR else COLOR_TEXT;

    rl.drawText("[1] Attack", @intFromFloat(mx + 10), @intFromFloat(my + 36), 16, atk_color);
    rl.drawText("[2] Defend", @intFromFloat(mx + 10), @intFromFloat(my + 60), 16, def_color);
    rl.drawText("[Enter] Confirm  [X] Cancel", @intFromFloat(mx + 10), @intFromFloat(my + 86), 13, COLOR_TEXT);
}

const std = @import("std");
