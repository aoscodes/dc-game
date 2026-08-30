//! The slime field: a server-authoritative grid of individual slime units
//! plus the off-grid reservoir that refills it.
//!
//! ## Model
//!
//! `SlimeField` owns a `SlimeGrid` (fixed rows × cols of `SlimeCell`) and a
//! `SlimeReservoir` of slime waiting to enter.  The encounter's total slime
//! starts in the reservoir; `fill` moves as much as fits onto the grid.
//!
//! Every operation that needs a choice takes a `std.Random` explicitly — this
//! module is pure with respect to randomness, so callers (the session) own
//! the seed and tests can pin it.  All randomness is therefore reproducible
//! and, because the grid is transmitted rather than simulated client-side,
//! every client sees the identical field.
//!
//! ## Operations
//!
//!   fill        — move reservoir slime into empty cells, RIGHTMOST COLUMN
//!                 FIRST (top-down within a column), so refills visibly enter
//!                 from the right — the far end of the conveyor.  Each unit's
//!                 type is drawn from the reservoir in proportion to what
//!                 remains.  With `specials_avoid_door_column`
//!                 (balance.Balance, default on) NO special is ever seated in
//!                 column 0 — the Lil Guys' mouths — and a `back_ranks_only`
//!                 special kind (balance.SpecialTuning) is only ever seated
//!                 in the rightmost BACK_RANKS columns; a cell whose eligible
//!                 pool is empty is SKIPPED, not filled.
//!   apply_shape — stamp a cast's footprint at an aimed anchor, DOWNGRADING
//!                 every covered hazard one tier and BREAKING every covered
//!                 rock into red slime.  Deterministic: the player chose the
//!                 cells, so nothing is random and nothing is destroyed —
//!                 only made safer (or, for a rock, made breakable-down).
//!   feast       — the turn-end bite: the Lil Guys chew through the leftmost
//!                 `n_cols` columns.  An EDIBLE unit is consumed whole; a
//!                 live hazard is NIBBLED — downgraded one tier in place,
//!                 filling hunger but scoring nothing; a rock is skipped,
//!                 or GNAWED for hunger alone where balance says so.
//!                 Specials are consumed with their effects: an egg HATCHES a
//!                 baby (reported, not resolved here), a neutralizer fires a
//!                 3x3 Agent block INLINE mid-bite, a canister refills
//!                 charges, a bomb detonates.
//!   shift_left  — pack every row's survivors against the left edge, so the
//!                 holes the bite (and any match pops) made drift to the
//!                 right for `fill` to refill: the conveyor's advance.
//!   resolve_matches — after the refill, pop every run of `match_len`+
//!                 same-kind matchable specials in a row or column and fire
//!                 the kind's effect at the run's central cell.  DORMANT: no
//!                 current kind matches; kept for a future one.
//!
//! ## The conveyor
//!
//! The Lil Guys stand still at the LEFT EDGE and the board comes to them:
//! every turn the bite hits the front `n_cols` columns cell by cell, the
//! survivors slide left into the space it opened, and fresh slime enters on
//! the right.  Nothing shelters anything — every cell in the bitten columns
//! is visited — so the strategic question of a turn is *what the front will
//! look like when the bite lands*: a hazard the casts defused in time is a
//! point on the plate, one they missed is a nibble that fills the hunger
//! clock and comes around again.
//!
//! Turn-end order is `feast` → `shift_left` → `fill`: bite the front, pack
//! the survivors left, then top the field up from the right.  The bite works
//! on the STANDING board — a neutralizer's block and a bomb's blast fire
//! inline where they were eaten, and nothing slides until the meal is over.
//!
//! Neither the reservoir nor an off-grid unit can be neutralized: casting is a
//! grid-only operation by construction (`SlimeReservoir` has no neutralized
//! bucket), so slime waiting off-grid always arrives at full difficulty.

const std = @import("std");
const c = @import("components.zig");
const balance = @import("balance.zig");

/// Grid + reservoir.  The single source of truth for slime state.
pub const SlimeField = struct {
    grid: c.SlimeGrid,
    reservoir: c.SlimeReservoir,

    /// Build a field of `dims` holding `total` slime: every
    /// `guaranteed_at_start` kind the supply holds is seated first (see
    /// seed_guaranteed), then as much as fits is placed on the grid
    /// (rightmost column first), the remainder stays in the reservoir.
    /// `bal` supplies the per-kind spawn rules the fill honours.
    pub fn init(
        dims: balance.SlimeGridDims,
        total: c.SlimeReservoir,
        bal: *const balance.Balance,
        rand: std.Random,
    ) SlimeField {
        var self = SlimeField{
            .grid = c.SlimeGrid.init(dims.rows, dims.cols),
            .reservoir = total,
        };
        self.seed_guaranteed(bal, rand);
        _ = self.fill(bal, rand);
        return self;
    }

    /// Seat one unit of every `guaranteed_at_start` kind (balance.
    /// SpecialTuning) the reservoir holds, BEFORE the initial fill, so the
    /// kind is on the grid at the start of play rather than gambling on the
    /// fill's uniform draw.  Each seeded unit lands in a uniform-random cell
    /// among the cells its spawn rules allow (`may_spawn`: never the door
    /// column, back-ranks kinds only in the back columns) and leaves the
    /// reservoir; the fill then tops up the rest of the grid as always.
    /// Kinds are walked in ordinal order and each seeding consumes exactly
    /// one draw — part of the lockstep contract the board's port mirrors.
    /// A kind with no reservoir units or no eligible cell is skipped.
    fn seed_guaranteed(self: *SlimeField, bal: *const balance.Balance, rand: std.Random) void {
        const n = self.grid.len();
        for (&self.reservoir.special, 0..) |*count, k| {
            const kind: c.SpecialKind = @enumFromInt(k);
            if (!bal.special_tuning(kind).guaranteed_at_start) continue;
            if (count.* == 0) continue;
            var eligible: u16 = 0;
            var flat: u16 = 0;
            while (flat < n) : (flat += 1) {
                if (self.grid.get(flat).is_slime()) continue;
                if (self.may_spawn(bal, kind, self.grid.col_of(flat))) eligible += 1;
            }
            if (eligible == 0) continue;
            var pick = rand.uintLessThan(u16, eligible);
            flat = 0;
            while (flat < n) : (flat += 1) {
                if (self.grid.get(flat).is_slime()) continue;
                if (!self.may_spawn(bal, kind, self.grid.col_of(flat))) continue;
                if (pick == 0) {
                    self.grid.put(flat, .{ .special = kind });
                    count.* -= 1;
                    break;
                }
                pick -= 1;
            }
        }
    }

    /// Total slime still in play: on the grid plus in the reservoir.
    pub fn remaining(self: *const SlimeField) u32 {
        return @as(u32, self.grid.occupied()) + self.reservoir.total();
    }

    /// True when nothing is left anywhere — grid and reservoir both empty.
    ///
    /// This is the WIN, and it is literally "eat everything": every unit can
    /// be cleared.  Food is eaten, hazards downgrade into food, and even a
    /// rock is broken into red slime by Neutralizing Agent — no unit is
    /// permanent, so nothing needs exempting from the count.
    pub fn is_exhausted(self: *const SlimeField) bool {
        return self.remaining() == 0;
    }

    /// Move reservoir slime into every empty cell, walking the RIGHTMOST
    /// column first (top-down within a column) so refills visibly enter from
    /// the right — the far end of the conveyor from the Lil Guys' mouths.
    /// Stops when the grid is full or the reservoir runs dry.  Returns the
    /// number of cells filled.
    ///
    /// With `specials_avoid_door_column` set (the default) NO special kind is
    /// ever seated in column 0 — the Lil Guys' mouths — and a
    /// `back_ranks_only` special kind may only be seated in the rightmost
    /// `balance.BACK_RANKS` columns — the far end of the conveyor.  Both are
    /// ENTRY restrictions: the conveyor drifts every unit leftward, so a
    /// restricted kind still reaches the front eventually — it just never
    /// STARTS there.  A cell whose ELIGIBLE pool is empty (the reservoir
    /// holds only restricted kinds) is SKIPPED, not filled, and the walk
    /// continues: other cells still take what is theirs.  A skipped cell
    /// consumes NO randomness — exactly one draw per cell filled, in this
    /// exact column-major right-to-left order, is the cross-implementation
    /// contract the browser's replay mirrors.
    pub fn fill(self: *SlimeField, bal: *const balance.Balance, rand: std.Random) u16 {
        var filled: u16 = 0;
        var col: u8 = self.grid.cols;
        while (col > 0) {
            col -= 1;
            var row: u8 = 0;
            while (row < self.grid.rows) : (row += 1) {
                const flat = self.grid.index(row, col);
                if (self.grid.get(flat).is_slime()) continue;
                if (self.reservoir.is_empty()) return filled;
                const cell = self.take_from_reservoir(bal, col, rand) orelse continue;
                self.grid.put(flat, cell);
                filled += 1;
            }
        }
        return filled;
    }

    /// True when a special kind may spawn in `col`.  Column 0 — the Lil
    /// Guys' mouths — is barred to EVERY special while
    /// `specials_avoid_door_column` is set (the default); beyond that a kind
    /// is either unrestricted or limited to the grid's rightmost
    /// `balance.BACK_RANKS` columns.
    fn may_spawn(self: *const SlimeField, bal: *const balance.Balance, kind: c.SpecialKind, col: u8) bool {
        if (bal.specials_avoid_door_column and col == 0) return false;
        if (!bal.special_tuning(kind).back_ranks_only) return true;
        return col >= self.grid.cols -| balance.BACK_RANKS;
    }

    /// Draw one unit for a cell in `col`, chosen uniformly among the ELIGIBLE
    /// units remaining (so the grid mixes in proportion to the reservoir's
    /// composition), where eligibility is `may_spawn` (no special in the door
    /// column, `back_ranks_only` kinds only in the back columns).  Returns
    /// null when nothing eligible remains —
    /// the caller skips the cell.  Buckets are walked in a fixed order
    /// (neutral, specials by ordinal, tiers), part of the lockstep contract.
    fn take_from_reservoir(
        self: *SlimeField,
        bal: *const balance.Balance,
        col: u8,
        rand: std.Random,
    ) ?c.SlimeCell {
        var eligible: u32 = self.reservoir.total();
        for (self.reservoir.special, 0..) |count, k| {
            if (!self.may_spawn(bal, @enumFromInt(k), col)) eligible -= count;
        }
        if (eligible == 0) return null;

        var pick = rand.uintLessThan(u32, eligible);
        if (pick < self.reservoir.neutral) {
            self.reservoir.neutral -= 1;
            return .neutral;
        }
        pick -= self.reservoir.neutral;
        for (&self.reservoir.special, 0..) |*count, k| {
            if (!self.may_spawn(bal, @enumFromInt(k), col)) continue;
            if (pick < count.*) {
                count.* -= 1;
                return .{ .special = @enumFromInt(k) };
            }
            pick -= count.*;
        }
        for (&self.reservoir.tiered, 0..) |*count, i| {
            if (pick < count.*) {
                count.* -= 1;
                return .{ .tiered = @enumFromInt(i) };
            }
            pick -= count.*;
        }
        unreachable; // `eligible` is the sum of the buckets just walked.
    }

    /// Stamp one cast's shape on the grid, anchored at (`row`, `col`).
    ///
    /// Every covered cell holding a hazard is DOWNGRADED one tier
    /// (red -> yellow -> green -> neutralized).  A covered ROCK is BROKEN:
    /// the Agent cracks it into red slime — the hardest tier — putting it at
    /// the top of the same ladder (rock -> red -> ... -> neutralized), so a
    /// rock is four applications from edible.  Nothing is destroyed: a
    /// neutralized unit stays on the grid, edible, scoring, and costing only
    /// normal hunger — clearing the field is the Lil Guys' job, not the cast's.
    ///
    /// Cells the shape covers that cannot be changed are WASTED, and the
    /// distinction is the player's aiming feedback:
    ///   - `off_grid`  — the offset fell outside the playfield (clipped)
    ///   - `inert`     — a real cell with nothing to neutralize (empty,
    ///                   neutral, already neutralized, or a special OTHER
    ///                   than the rock — no cast can change those)
    ///
    /// Deterministic: no randomness, because the player chose the cells.
    pub fn apply_shape(
        self: *SlimeField,
        shape: balance.Shape,
        row: u8,
        col: u8,
    ) ShapeOutcome {
        std.debug.assert(row < self.grid.rows and col < self.grid.cols);
        var out = ShapeOutcome{};

        for (shape.offsets) |off| {
            const r = @as(i32, row) + off.d_row;
            const cl = @as(i32, col) + off.d_col;
            if (r < 0 or r >= self.grid.rows or cl < 0 or cl >= self.grid.cols) {
                out.off_grid += 1;
                continue;
            }
            const flat = self.grid.index(@intCast(r), @intCast(cl));
            const cell = self.grid.get(flat);
            if (cell == .special and cell.special == .rock) {
                // The BREAK: the Agent cracks the boulder into the hardest
                // slime.  Accomplishment, not waste — it goes on its own
                // tally, never into `inert` or the per-tier `downgraded`.
                self.grid.put(flat, .{ .tiered = .red });
                out.rocks_broken += 1;
                continue;
            }
            if (cell != .tiered) {
                out.inert += 1;
                continue;
            }
            const tier = cell.tiered;
            if (tier.downgrade()) |next| {
                self.grid.put(flat, .{ .tiered = next });
                out.downgraded[@intFromEnum(tier)] += 1;
            } else {
                self.grid.put(flat, .neutralized);
                out.downgraded[@intFromEnum(tier)] += 1;
                out.neutralized += 1;
            }
        }
        return out;
    }

    /// The turn-end bite: the Lil Guys chew through the leftmost `n_cols`
    /// columns (clamped to the grid), cell by cell, on the STANDING board.
    ///
    /// The walk is COLUMN-MAJOR from the front: column 0 top-down, then
    /// column 1, and so on — that order is part of the cross-implementation
    /// contract the browser's replay mirrors, because inline effects make it
    /// observable.  Each visited cell is one of:
    ///
    ///   - EDIBLE (neutral, neutralized, consumable special) — consumed via
    ///     `consume`: food scores and fills hunger, equipment is free, and a
    ///     special's effect fires INLINE — an egg's hatch is recorded, a
    ///     neutralizer's 3x3 Agent block stamps the standing board (so a
    ///     hazard later in this same bite can be defused in time to be
    ///     consumed rather than nibbled), a canister refills charges, and a
    ///     bomb's blast levels its 3x3 (a cell it empties ahead of the walk
    ///     is simply skipped when reached).
    ///   - A LIVE HAZARD — NIBBLED: downgraded one tier in place
    ///     (red -> yellow -> green -> defused), never removed.  A nibble
    ///     fills hunger like a meal but scores NOTHING: hazards the casts
    ///     failed to defuse in time run the clock down for free.
    ///   - A ROCK (inconsumable special) — never swallowed and never moved
    ///     by the bite.  With the kind's `bite_costs_hunger` off it is
    ///     skipped outright (no hunger, no score, no change); with it on the
    ///     bite GNAWS it: hunger fills, nothing scores, the rock stays, and
    ///     the next bite gnaws it again.  Either way the bite cannot break
    ///     one: only Neutralizing Agent (a cast or an inline block, cracking
    ///     it to red) starts it down the ladder, and only a bomb removes one
    ///     instantly.
    ///   - EMPTY — nothing there.
    ///
    /// Nothing shelters anything: every cell in the bitten columns is
    /// visited exactly once, and the board does not slide until the meal is
    /// over (the caller's next steps are `shift_left`, then `fill`).
    ///
    /// Deterministic: no randomness, one pass, front-to-back.
    pub fn feast(self: *SlimeField, bal: *const balance.Balance, n_cols: u8) FeastOutcome {
        var out = FeastOutcome{};

        const width = @min(n_cols, self.grid.cols);
        var col: u8 = 0;
        while (col < width) : (col += 1) {
            var row: u8 = 0;
            while (row < self.grid.rows) : (row += 1) {
                const flat = self.grid.index(row, col);
                const cell = self.grid.get(flat);
                if (cell == .tiered) {
                    // The NIBBLE: one downgrade in place, hunger but no
                    // score.  The survivor stays put and rides the conveyor
                    // into next turn's bite.
                    const tier = cell.tiered;
                    out.bitten_downgraded[@intFromEnum(tier)] += 1;
                    out.hunger += bal.hunger_cost_normal;
                    if (tier.downgrade()) |next| {
                        self.grid.put(flat, .{ .tiered = next });
                    } else {
                        self.grid.put(flat, .neutralized);
                        out.bitten_defused += 1;
                    }
                    continue;
                }
                if (cell == .special and !cell.special.consumable()) {
                    // The GNAW: teeth on something they cannot swallow.  Off
                    // by default the rock is inert and this is a plain skip;
                    // on, the mouths chew stone — hunger fills, nothing
                    // scores, and the rock is untouched, so it is gnawed
                    // again every bite until an Agent cracks it.
                    if (bal.special_tuning(cell.special).bite_costs_hunger) {
                        out.gnawed += 1;
                        out.hunger += bal.hunger_cost_normal;
                    }
                    continue;
                }
                if (!cell.is_edible()) continue; // empty
                const effect = self.consume(flat, bal, &out) orelse continue;
                switch (effect) {
                    // Recorded in `consume`; nothing on the board changes.
                    .hatch, .refill_charges => {},
                    .neutralize_block => {
                        // The 3x3 fires where the neutralizer was eaten, on
                        // the board AS IT STANDS — a cell it defuses later
                        // in this same bite is consumed when reached.
                        out.agents += 1;
                        const fired = self.apply_shape(
                            AGENT_BLOCK,
                            self.grid.row_of(flat),
                            self.grid.col_of(flat),
                        );
                        for (fired.downgraded, 0..) |n, t| {
                            out.agent_downgraded[t] += n;
                        }
                        out.agent_defused += fired.neutralized;
                        out.agent_rocks_broken += fired.rocks_broken;
                    },
                    .explode => {
                        // The blast levels the 3x3 where the bomb was eaten,
                        // on the board AS IT STANDS — a cell it empties
                        // ahead of the walk is skipped when reached.
                        out.bombs += 1;
                        out.destroyed += self.detonate(
                            flat,
                            bal.special_tuning(.bomb).explode_rocks_only,
                        );
                    },
                }
            }
        }
        return out;
    }

    /// Eat the edible unit at `flat`, accruing hunger and score for FOOD
    /// kinds and recording an egg's hatch.  Returns the special's on-eat
    /// effect (null for plain slime) so `feast` can resolve a
    /// board-changing one: the neutralizer's block fires on the STANDING
    /// board — mid-bite, no slide — right where the cell was eaten.
    fn consume(
        self: *SlimeField,
        flat: u16,
        bal: *const balance.Balance,
        out: *FeastOutcome,
    ) ?c.SpecialEffect {
        const cell = self.grid.get(flat);
        switch (cell) {
            .empty => unreachable, // feast only consumes edible cells
            .neutral => out.neutral += 1,
            .neutralized => out.defused += 1,
            .special => |kind| {
                // Only a consumable special is ever consumed: feast skips
                // inconsumable ones (the rock) before calling here.
                std.debug.assert(kind.consumable());
                self.grid.put(flat, .empty);
                out.cells += 1;
                if (kind.eat_is_food()) {
                    out.score += 1;
                    out.hunger += bal.hunger_cost_normal;
                }
                const effect = kind.eat_effect() orelse return null;
                switch (effect) {
                    .hatch => {
                        // Recorded by CELL so the caller can roll each baby's
                        // type and the client can animate the hatch in place.
                        out.hatched_cells[out.hatched] = flat;
                        out.hatched += 1;
                    },
                    // Resolved by `feast` on the standing board.
                    .neutralize_block, .explode => {},
                    .refill_charges => {
                        // Tallied here; the session credits the team pool.
                        out.canisters += 1;
                        out.charges_refilled +|=
                            bal.special_tuning(kind).charge_refill;
                    },
                }
                return effect;
            },
            .tiered => unreachable, // feast nibbles hazards, never consumes them
        }
        out.cells += 1;
        out.score += 1;
        out.hunger += bal.hunger_cost_normal;
        self.grid.put(flat, .empty);
        return null;
    }

    /// The bomb's blast: DESTROY every unit in the 3x3 around `flat` — or,
    /// with `rocks_only`, just the rocks in it (the one tool that can remove
    /// one).  Destroyed units leave play outright: no score, no hunger, and
    /// nothing returns to the reservoir.  Walked in row-major offset order,
    /// the same order every implementation mirrors.  Returns the number of
    /// units destroyed.
    fn detonate(self: *SlimeField, flat: u16, rocks_only: bool) u16 {
        var destroyed: u16 = 0;
        const r = self.grid.row_of(flat);
        const cl = self.grid.col_of(flat);
        var dr: i32 = -1;
        while (dr <= 1) : (dr += 1) {
            var dc: i32 = -1;
            while (dc <= 1) : (dc += 1) {
                const nr = @as(i32, r) + dr;
                const nc = @as(i32, cl) + dc;
                if (nr < 0 or nr >= self.grid.rows or
                    nc < 0 or nc >= self.grid.cols) continue;
                const cell = self.grid.at(@intCast(nr), @intCast(nc));
                if (!cell.is_slime()) continue;
                if (rocks_only) {
                    const is_rock = switch (cell) {
                        .special => |kind| kind == .rock,
                        else => false,
                    };
                    if (!is_rock) continue;
                }
                self.grid.set(@intCast(nr), @intCast(nc), .empty);
                destroyed += 1;
            }
        }
        return destroyed;
    }

    /// Pack every row's surviving units against the LEFT edge, preserving
    /// the order within the row, so the holes the bite punched drift to the
    /// right for `fill` to refill: the conveyor's advance.
    ///
    /// The slide is what carries the back of the board to the front: a unit
    /// spawned in the back ranks steps left every time the cells ahead of it
    /// are eaten, until it is at the Lil Guys' mouths itself.  It never
    /// changes row — a unit rides its own lane the whole way.
    ///
    /// Returns the number of units that moved (0 when every row is already
    /// packed against the left edge).
    pub fn shift_left(self: *SlimeField) u16 {
        var moved: u16 = 0;
        var row: u8 = 0;
        while (row < self.grid.rows) : (row += 1) {
            // Walk left-to-right, packing units against the left edge:
            // `write` is the leftmost cell still free to receive one.
            var write: u8 = 0;
            var read: u8 = 0;
            while (read < self.grid.cols) : (read += 1) {
                const cell = self.grid.at(row, read);
                if (!cell.is_slime()) continue;
                if (read != write) {
                    self.grid.set(row, write, cell);
                    self.grid.set(row, read, .empty);
                    moved += 1;
                }
                write += 1;
            }
        }
        return moved;
    }

    /// Pop every MATCH on the grid and fire its effect.  Run once per turn,
    /// right after `fill` — the refill is what lines new specials up, so this
    /// is the moment lines can first exist.  A single pass, no cascade: holes
    /// the pops leave are tidied by the settle loop's next shift_left.
    ///
    /// A match is `match_len(kind)`+ same-kind MATCHABLE specials contiguous
    /// in one row or column (no diagonals).  A longer run is ONE match.  Every
    /// matched cell goes `.empty`, then the kind's effect fires at the run's
    /// central cell (even-length runs: the earlier middle).  A cell shared by
    /// a row run and a column run belongs to both matches but is popped once.
    ///
    /// All matches are DETECTED first, on the grid as `fill` left it, then
    /// popped, then effects land in detection order (rows top-down, then
    /// columns left-right) — so one match's pops can never break another's
    /// detection, and resolution is deterministic.
    pub fn resolve_matches(self: *SlimeField, bal: *const balance.Balance) MatchOutcome {
        var out = MatchOutcome{};

        // Detect along every row, then every column.
        var row: u8 = 0;
        while (row < self.grid.rows) : (row += 1) {
            self.scan_line(bal, &out, self.grid.index(row, 0), 1, self.grid.cols);
        }
        var col: u8 = 0;
        while (col < self.grid.cols) : (col += 1) {
            self.scan_line(bal, &out, self.grid.index(0, col), self.grid.cols, self.grid.rows);
        }

        // Pop every matched cell (union across matches), then fire effects.
        for (out.matches[0..out.count]) |m| {
            for (m.cells[0..m.len]) |flat| self.grid.put(flat, .empty);
        }
        for (out.matches[0..out.count]) |*m| {
            switch (m.kind.match_effect() orelse unreachable) { // only matchable kinds are detected
                .neutralize_block => {
                    const shape_out = self.apply_shape(
                        NEUTRALIZE_BLOCK,
                        self.grid.row_of(m.center),
                        self.grid.col_of(m.center),
                    );
                    m.downgraded = shape_out.downgraded;
                    m.neutralized = shape_out.neutralized;
                    m.rocks_broken = shape_out.rocks_broken;
                },
                // On-eat effects; no matchable kind carries them.
                .hatch, .refill_charges, .explode => unreachable,
            }
        }
        return out;
    }

    /// Scan one grid line (a row or a column) for matched runs.  `start` is
    /// the line's first flat index, `stride` the flat step between neighbours
    /// (1 along a row, `cols` down a column), `count` the line's cell count.
    fn scan_line(
        self: *const SlimeField,
        bal: *const balance.Balance,
        out: *MatchOutcome,
        start: u16,
        stride: u16,
        count: u16,
    ) void {
        var i: u16 = 0;
        while (i < count) {
            const flat = start + i * stride;
            const cell = self.grid.get(flat);
            // Only a matchable special can seed a run.
            if (cell != .special or cell.special.match_effect() == null) {
                i += 1;
                continue;
            }
            const kind = cell.special;
            var run: u16 = 1;
            while (i + run < count) : (run += 1) {
                const next = self.grid.get(start + (i + run) * stride);
                if (next != .special or next.special != kind) break;
            }
            if (run >= bal.special_tuning(kind).match_len) {
                var m = Match{ .kind = kind, .center = 0 };
                var j: u16 = 0;
                while (j < run) : (j += 1) {
                    m.cells[j] = start + (i + j) * stride;
                }
                m.len = @intCast(run);
                // "The more central square": the run's middle cell; an
                // even-length run takes the earlier of its two middles.
                m.center = m.cells[(run - 1) / 2];
                out.matches[out.count] = m;
                out.count += 1;
            }
            i += run;
        }
    }
};

/// The footprint an EATEN neutralizer's Agent release covers: a 3x3 block
/// around the cell it was consumed on.  Downgrades exactly like a cast (see
/// apply_shape) — hard-coded, not a recipe, because no player casts it.
pub const AGENT_BLOCK = balance.Shape{
    .offsets = &agent_block_offsets,
    .rows = 3,
    .cols = 3,
};

const agent_block_offsets = blk: {
    var offs: [9]balance.ShapeOffset = undefined;
    var n: usize = 0;
    for (0..3) |r| {
        for (0..3) |cl| {
            offs[n] = .{ .d_row = @as(i8, @intCast(r)) - 1, .d_col = @as(i8, @intCast(cl)) - 1 };
            n += 1;
        }
    }
    break :blk offs;
};

/// The footprint a special MATCH's Agent release covers: a 5x5 block around
/// the matched run's central cell.  DORMANT alongside resolve_matches — no
/// current kind matches — but kept wired for a future one.
pub const NEUTRALIZE_BLOCK = balance.Shape{
    .offsets = &neutralize_block_offsets,
    .rows = 5,
    .cols = 5,
};

const neutralize_block_offsets = blk: {
    var offs: [25]balance.ShapeOffset = undefined;
    var n: usize = 0;
    for (0..5) |r| {
        for (0..5) |cl| {
            offs[n] = .{ .d_row = @as(i8, @intCast(r)) - 2, .d_col = @as(i8, @intCast(cl)) - 2 };
            n += 1;
        }
    }
    break :blk offs;
};

/// The longest line a grid can hold — the cap on one matched run's cell list.
pub const MAX_MATCH_CELLS: u8 = @max(c.MAX_GRID_ROWS, c.MAX_GRID_COLS);

/// Cap on matches one resolution can find.  The tightest packing is runs of
/// two with one separator (match_len >= 2 by config): ceil(17/3) = 5 runs per
/// 16-cell line, over at most 16 rows + 16 cols of lines.
pub const MAX_MATCHES: u16 = 5 * (@as(u16, c.MAX_GRID_ROWS) + c.MAX_GRID_COLS);

/// One matched run: which kind, which cells popped, and what its effect did.
pub const Match = struct {
    kind: c.SpecialKind,
    /// The run's central cell — where the effect landed.
    center: u16,
    /// The popped cells, in line order.  Only the first `len` are live.
    cells: [MAX_MATCH_CELLS]u16 = [_]u16{0} ** MAX_MATCH_CELLS,
    len: u8 = 0,
    /// What the effect downgraded, per tier it was AT (neutralize_block only).
    downgraded: [c.Tier.size]u16 = [_]u16{0} ** c.Tier.size,
    /// Of those, cells taken all the way to defused.
    neutralized: u16 = 0,
    /// Rocks the effect BROKE into red slime (neutralize_block only).
    rocks_broken: u16 = 0,
};

/// Everything one `resolve_matches` pass found and did.
pub const MatchOutcome = struct {
    matches: [MAX_MATCHES]Match = undefined,
    count: u16 = 0,

    /// Special units popped off the grid, across every match (shared cells
    /// counted once per match they close, popped once).
    pub fn popped(self: *const MatchOutcome) u16 {
        var n: u16 = 0;
        for (self.matches[0..self.count]) |m| n += m.len;
        return n;
    }
};

/// What one feast produced.
///
/// Hunger is a single flat rate: a consumed unit and a nibbled hazard fill
/// the bar identically, so the interesting split is `cells` (consumed, all
/// of which score) against `bitten_downgraded` (nibbled — hunger for
/// nothing, the price of a front the casts failed to defuse in time).
pub const FeastOutcome = struct {
    /// Slime units eaten.
    cells: u16 = 0,
    /// Of those, units that were never hazardous.
    neutral: u16 = 0,
    /// Of those, units a cast had taken all the way to defused.
    defused: u16 = 0,
    /// Live hazards the bite NIBBLED — downgraded one tier in place, hunger
    /// but no score — per tier they were AT when bitten.  The team's main
    /// feedback: high here means the front reached the mouths still hot.
    bitten_downgraded: [c.Tier.size]u16 = [_]u16{0} ** c.Tier.size,
    /// Of those, nibbles that took a green all the way to defused (next
    /// bite, that unit is food).
    bitten_defused: u16 = 0,
    /// Units the bite GNAWED: inconsumable specials (rocks) whose kind has
    /// `bite_costs_hunger` set, each of which filled hunger and did nothing
    /// else.  Zero unless that flag is on, in which case it is pure waste —
    /// counted apart from `bitten_downgraded` because a gnaw does not even
    /// move the unit down a tier.
    gnawed: u16 = 0,
    /// Eggs eaten, and where each sat: one baby hatches per entry.  The type
    /// roll is the caller's (the session owns the seed); this module only
    /// reports the eggs.  Only the first `hatched` entries are live.
    hatched: u16 = 0,
    hatched_cells: [c.MAX_GRID_CELLS]u16 = [_]u16{0} ** c.MAX_GRID_CELLS,
    /// Neutralizers consumed.  Free — counted in `cells` but never in score
    /// or hunger — each firing a 3x3 Agent block as it was swallowed.
    agents: u16 = 0,
    /// What those blocks downgraded, per tier the cell was AT, and how many
    /// went all the way to defused (most of which this same feast then ate).
    agent_downgraded: [c.Tier.size]u16 = [_]u16{0} ** c.Tier.size,
    agent_defused: u16 = 0,
    /// Rocks those blocks BROKE into red slime (see ShapeOutcome).
    agent_rocks_broken: u16 = 0,
    /// Canisters consumed.  Free like the neutralizer — counted in `cells`,
    /// never in score or hunger.
    canisters: u16 = 0,
    /// Charges the swallowed canisters refill into the team pool
    /// (`charge_refill` per canister); the caller credits the pool.
    charges_refilled: u32 = 0,
    /// Bombs consumed.  Free — counted in `cells`, never in score or hunger
    /// — each destroying its 3x3 surroundings as it was swallowed.
    bombs: u16 = 0,
    /// Units the bombs DESTROYED: removed from play outright, not eaten —
    /// no score, no hunger, and nothing returns to the reservoir.
    destroyed: u16 = 0,
    /// Hunger added: `hunger_cost_normal` per BITE — consumed food and
    /// nibbled hazards alike (free equipment excepted).
    hunger: u32 = 0,
    /// Score: 1 per unit CONSUMED (all consumed units are neutral, defused,
    /// or food-shaped specials).  Nibbles never score.
    score: u32 = 0,

    /// Total hazards the bite nibbled, across every tier.
    pub fn total_bitten(self: FeastOutcome) u16 {
        var n: u16 = 0;
        for (self.bitten_downgraded) |d| n += d;
        return n;
    }

    /// Total hunger the feast added.  Kept as a method so callers read the same
    /// way they did when hunger had several components.
    pub fn hunger_total(self: FeastOutcome) u32 {
        return self.hunger;
    }
};

/// What stamping one shape did.  The two wasted-cell kinds are kept apart
/// because they mean different things to the player: `off_grid` says "you
/// aimed off the edge", `inert` says "you hit clean slime".
pub const ShapeOutcome = struct {
    /// Cells downgraded, indexed by the tier they were AT before the cast.
    downgraded: [c.Tier.size]u16 = [_]u16{0} ** c.Tier.size,
    /// Of those, how many were fully defused (green -> neutralized).
    neutralized: u16 = 0,
    /// Rocks BROKEN into red slime.  Kept out of `downgraded` — a rock had
    /// no tier to step down FROM — and out of the waste tallies: cracking a
    /// boulder is what the Agent was for.
    rocks_broken: u16 = 0,
    /// Covered offsets that fell outside the grid.
    off_grid: u16 = 0,
    /// Covered cells with nothing to neutralize.
    inert: u16 = 0,

    /// Total cells the cast stepped down a tier (breaks not included).
    pub fn total_downgraded(self: ShapeOutcome) u16 {
        var n: u16 = 0;
        for (self.downgraded) |d| n += d;
        return n;
    }

    /// Covered cells the cast achieved nothing on.
    pub fn wasted(self: ShapeOutcome) u16 {
        return self.off_grid + self.inert;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const test_bal = &fixtures.test_config.balance;

/// Deterministic randomness for tests.
fn prng(seed: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(seed);
}

fn ti(t: c.Tier) usize {
    return @intFromEnum(t);
}

/// A shape from authored rows, for tests only (config.zig does this at load).
/// `rows` are `#`/`.` strings; anchor is the bounding box centre, rounded down.
/// The offsets live in a generated namespace so the returned slice is static.
fn Shaped(comptime rows: []const []const u8) type {
    return struct {
        const offsets = blk: {
            var offs: [balance.MAX_SHAPE_CELLS]balance.ShapeOffset = undefined;
            var n: usize = 0;
            const anchor_r: i8 = @intCast(rows.len / 2);
            const anchor_c: i8 = @intCast(rows[0].len / 2);
            for (rows, 0..) |line, r| {
                for (line, 0..) |ch, cl| {
                    if (ch != '#') continue;
                    offs[n] = .{
                        .d_row = @as(i8, @intCast(r)) - anchor_r,
                        .d_col = @as(i8, @intCast(cl)) - anchor_c,
                    };
                    n += 1;
                }
            }
            break :blk offs[0..n].*;
        };
        const shape = balance.Shape{
            .offsets = &offsets,
            .rows = @intCast(rows.len),
            .cols = @intCast(rows[0].len),
        };
    };
}

fn test_shape(comptime rows: []const []const u8) balance.Shape {
    return Shaped(rows).shape;
}

const SQUARE_3X3 = test_shape(&.{ "###", "###", "###" });
const DOT = test_shape(&.{"#"});
const PLUS = test_shape(&.{ ".#.", "###", ".#." });

/// Paint every live cell of a field, bypassing the reservoir.
fn paint(field: *SlimeField, cell: c.SlimeCell) void {
    var flat: u16 = 0;
    while (flat < field.grid.len()) : (flat += 1) field.grid.put(flat, cell);
}

fn empty_field(rows: u8, cols: u8) SlimeField {
    return .{ .grid = c.SlimeGrid.init(rows, cols), .reservoir = .{} };
}

test "Tier.downgrade walks red -> yellow -> green -> defused" {
    try testing.expectEqual(c.Tier.yellow, c.Tier.red.downgrade().?);
    try testing.expectEqual(c.Tier.green, c.Tier.yellow.downgrade().?);
    // Green has no lower tier: the next application defuses the unit.
    try testing.expectEqual(@as(?c.Tier, null), c.Tier.green.downgrade());
}

test "init fills the grid from the reservoir and keeps the overflow" {
    var rng = prng(1);
    var res = c.SlimeReservoir{ .neutral = 20 };
    res.tiered[ti(.red)] = 30;
    const field = SlimeField.init(.{ .rows = 2, .cols = 3 }, res, test_bal, rng.random());

    // 6 cells filled, 50 - 6 = 44 left in the reservoir.
    try testing.expectEqual(@as(u16, 6), field.grid.occupied());
    try testing.expectEqual(@as(u32, 44), field.reservoir.total());
    try testing.expectEqual(@as(u32, 50), field.remaining());
    try testing.expect(!field.is_exhausted());
}

test "init leaves cells empty when the reservoir cannot fill the grid" {
    var rng = prng(2);
    const field = SlimeField.init(.{ .rows = 4, .cols = 4 }, .{ .neutral = 5 }, test_bal, rng.random());
    try testing.expectEqual(@as(u16, 5), field.grid.occupied());
    try testing.expect(field.reservoir.is_empty());
    // Filled from the right: all of column 3, then the top of column 2.
    var row: u8 = 0;
    while (row < 4) : (row += 1) {
        var col: u8 = 0;
        while (col < 4) : (col += 1) {
            const expected = col == 3 or (col == 2 and row == 0);
            try testing.expectEqual(expected, field.grid.at(row, col).is_slime());
        }
    }
}

test "fill refills empty cells from the rightmost column inward" {
    var rng = prng(3);
    var field = SlimeField.init(.{ .rows = 3, .cols = 2 }, .{ .neutral = 6 }, test_bal, rng.random());
    try testing.expect(field.reservoir.is_empty());

    field.grid.set(0, 0, .empty);
    field.grid.set(0, 1, .empty);
    field.grid.set(2, 1, .empty);
    field.reservoir.neutral = 2;

    const filled = field.fill(test_bal, rng.random());
    // Only 2 units available, and they go to the two RIGHTMOST empty cells:
    // new slime enters at the far end of the conveyor.
    try testing.expectEqual(@as(u16, 2), filled);
    try testing.expect(field.grid.at(0, 1).is_slime());
    try testing.expect(field.grid.at(2, 1).is_slime());
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 0));
}

test "fill draws every reservoir bucket and exhausts it exactly" {
    var rng = prng(4);
    var res = c.SlimeReservoir{ .neutral = 4 };
    res.tiered[ti(.red)] = 4;
    res.tiered[ti(.green)] = 4;
    const field = SlimeField.init(.{ .rows = 3, .cols = 4 }, res, test_bal, rng.random());

    try testing.expectEqual(@as(u16, 12), field.grid.occupied());
    try testing.expect(field.reservoir.is_empty());
    // Composition is preserved exactly (only the placement is random).
    var neutral: u16 = 0;
    for (field.grid.live()) |cell| {
        if (cell == .neutral) neutral += 1;
    }
    try testing.expectEqual(@as(u16, 4), neutral);
    try testing.expectEqual(@as(u16, 4), field.grid.tier_count(.red));
    try testing.expectEqual(@as(u16, 4), field.grid.tier_count(.green));
}

test "a back_ranks_only special is only ever seated in the rightmost BACK_RANKS columns" {
    // All-egg reservoir on a 3x4 grid: only the back two columns may seat
    // one, so the six front cells are SKIPPED — left empty, no draw spent —
    // while the six back cells fill.
    var bal = fixtures.test_config.balance;
    bal.specials[@intFromEnum(c.SpecialKind.egg)].back_ranks_only = true;

    var rng = prng(7);
    const res = c.SlimeReservoir{ .special = .{ 0, 20, 0, 0, 0 } };
    var field = SlimeField.init(.{ .rows = 3, .cols = 4 }, res, &bal, rng.random());

    try testing.expectEqual(@as(u16, 6), field.grid.occupied());
    var row: u8 = 0;
    while (row < 3) : (row += 1) {
        var col: u8 = 0;
        while (col < 4) : (col += 1) {
            const expected: c.SlimeCell = if (col >= 2) .{ .special = .egg } else .empty;
            try testing.expectEqual(expected, field.grid.at(row, col));
        }
    }
    try testing.expectEqual(@as(u32, 14), field.reservoir.total());
}

test "restricted eggs ENTER in the back ranks; the conveyor then carries them left" {
    // back_ranks_only is an ENTRY restriction: a fill only ever seats an egg
    // in the back columns, but the shift drifts it toward the mouths turn by
    // turn — that ride is the point, so drifting left is CORRECT here.
    var bal = fixtures.test_config.balance;
    bal.specials[@intFromEnum(c.SpecialKind.egg)].back_ranks_only = true;

    var rng = prng(21);
    var res = c.SlimeReservoir{ .neutral = 30, .special = .{ 0, 10, 0, 0, 0 } };
    res.tiered[ti(.red)] = 6;
    var field = SlimeField.init(.{ .rows = 4, .cols = 4 }, res, &bal, rng.random());

    var turns: u8 = 0;
    while (turns < 8) : (turns += 1) {
        // Every fresh SEATING honours the restriction: snapshot which cells
        // were empty, fill, and demand any egg that appeared in one of them
        // sits in the back ranks.
        var was_empty = [_]bool{false} ** c.MAX_GRID_CELLS;
        var flat: u16 = 0;
        while (flat < field.grid.len()) : (flat += 1) {
            was_empty[flat] = !field.grid.get(flat).is_slime();
        }
        _ = field.fill(&bal, rng.random());
        flat = 0;
        while (flat < field.grid.len()) : (flat += 1) {
            if (!was_empty[flat]) continue;
            switch (field.grid.get(flat)) {
                .special => |kind| if (kind == .egg) {
                    try testing.expect(field.grid.col_of(flat) >= 4 - balance.BACK_RANKS);
                },
                else => {},
            }
        }
        _ = field.feast(&bal, 1);
        _ = field.shift_left();
    }
}

test "a guaranteed_at_start kind is seated at the start of play whatever the seed" {
    // 1 egg among 100 hazards on a 4x4 grid: a pure uniform fill would
    // usually leave the egg in the reservoir, so every seed passing is the
    // guarantee at work, not luck.  The seeded egg still obeys the kind's
    // spawn rules: back ranks only, never the door column.
    var bal = fixtures.test_config.balance;
    bal.specials[@intFromEnum(c.SpecialKind.egg)].back_ranks_only = true;
    bal.specials[@intFromEnum(c.SpecialKind.egg)].guaranteed_at_start = true;

    var seed: u64 = 0;
    while (seed < 32) : (seed += 1) {
        var rng = prng(seed);
        var res = c.SlimeReservoir{ .special = .{ 0, 1, 0, 0, 0 } };
        res.tiered[ti(.red)] = 100;
        var field = SlimeField.init(.{ .rows = 4, .cols = 4 }, res, &bal, rng.random());

        var eggs: u16 = 0;
        var flat: u16 = 0;
        while (flat < field.grid.len()) : (flat += 1) {
            switch (field.grid.get(flat)) {
                .special => |kind| if (kind == .egg) {
                    eggs += 1;
                    try testing.expect(field.grid.col_of(flat) >= 4 - balance.BACK_RANKS);
                },
                else => {},
            }
        }
        try testing.expectEqual(@as(u16, 1), eggs);
        // The seeded egg left the reservoir, not thin air: slime is conserved.
        try testing.expectEqual(@as(u32, 101), field.remaining());
    }
}

test "guaranteed_at_start seeds nothing when the supply holds none of the kind" {
    var bal = fixtures.test_config.balance;
    bal.specials[@intFromEnum(c.SpecialKind.egg)].guaranteed_at_start = true;

    var rng = prng(3);
    const res = c.SlimeReservoir{ .neutral = 5 };
    var field = SlimeField.init(.{ .rows = 2, .cols = 3 }, res, &bal, rng.random());

    try testing.expectEqual(@as(u16, 5), field.grid.occupied());
    for (field.grid.live()) |cell| {
        try testing.expect(cell != .special);
    }
}

test "guaranteed_at_start is a no-op when no cell may seat the kind" {
    // A single-column grid with the door restriction (the default) bars
    // every cell to specials: the guarantee cannot fire, the egg waits in
    // the reservoir, and the rest of the fill proceeds untouched.
    var bal = fixtures.test_config.balance;
    bal.specials[@intFromEnum(c.SpecialKind.egg)].guaranteed_at_start = true;

    var rng = prng(5);
    const res = c.SlimeReservoir{ .neutral = 2, .special = .{ 0, 1, 0, 0, 0 } };
    var field = SlimeField.init(.{ .rows = 3, .cols = 1 }, res, &bal, rng.random());

    try testing.expectEqual(@as(u16, 1), field.reservoir.special[@intFromEnum(c.SpecialKind.egg)]);
    try testing.expectEqual(@as(u16, 2), field.grid.occupied());
}

test "an unrestricted egg spawns anywhere but the door column (the default)" {
    // Default tuning: no back-ranks restriction, but the door column is
    // still barred to every special.  The right-to-left fill seats the lone
    // egg in the FIRST cell it walks — the rightmost — and never column 0.
    var rng = prng(9);
    const res = c.SlimeReservoir{ .special = .{ 0, 1, 0, 0, 0 } };
    const field = SlimeField.init(.{ .rows = 1, .cols = 3 }, res, test_bal, rng.random());
    try testing.expectEqual(c.SlimeCell{ .special = .egg }, field.grid.get(2));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.get(1));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.get(0));
}

test "no special is ever seated in the door column (the default)" {
    // All-rock reservoir (an unrestricted kind) on a 2x3 grid: the two
    // door-column cells are SKIPPED — left empty, no draw spent — while the
    // four other cells fill.
    var rng = prng(11);
    const res = c.SlimeReservoir{ .special = .{ 0, 0, 20, 0, 0 } };
    var field = SlimeField.init(.{ .rows = 2, .cols = 3 }, res, test_bal, rng.random());

    try testing.expectEqual(@as(u16, 4), field.grid.occupied());
    var row: u8 = 0;
    while (row < 2) : (row += 1) {
        var col: u8 = 0;
        while (col < 3) : (col += 1) {
            const expected: c.SlimeCell = if (col == 0) .empty else .{ .special = .rock };
            try testing.expectEqual(expected, field.grid.at(row, col));
        }
    }
    try testing.expectEqual(@as(u32, 16), field.reservoir.total());
}

test "specials_avoid_door_column off lets a special seat in column 0" {
    var bal = fixtures.test_config.balance;
    bal.specials_avoid_door_column = false;

    // A single-column grid: the only cell IS the door column, so a seated
    // egg proves the restriction is off (the default would skip the cell).
    var rng = prng(9);
    const res = c.SlimeReservoir{ .special = .{ 0, 1, 0, 0, 0 } };
    const field = SlimeField.init(.{ .rows = 1, .cols = 1 }, res, &bal, rng.random());
    try testing.expectEqual(c.SlimeCell{ .special = .egg }, field.grid.get(0));
}

test "reservoir slime always arrives at full difficulty" {
    // Casting cannot reach off-grid slime, so a refill after a cast brings in
    // an un-neutralized unit even though the grid was just cleaned.
    var rng = prng(16);
    var field = empty_field(1, 2);
    field.grid.put(0, .{ .tiered = .green });
    field.reservoir.tiered[ti(.red)] = 1;

    _ = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.get(0));

    _ = field.fill(test_bal, rng.random());
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.get(1));
}

test "apply_shape downgrades every covered hazard one tier" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .red });

    const out = field.apply_shape(SQUARE_3X3, 1, 1);
    try testing.expectEqual(@as(u16, 9), out.total_downgraded());
    try testing.expectEqual(@as(u16, 9), out.downgraded[ti(.red)]);
    try testing.expectEqual(@as(u16, 0), out.neutralized);
    try testing.expectEqual(@as(u16, 0), out.wasted());
    // All nine are now yellow — one step, not straight to defused.
    try testing.expectEqual(@as(u16, 9), field.grid.tier_count(.yellow));
    try testing.expectEqual(@as(u16, 0), field.grid.tier_count(.red));
}

test "a red cell takes three casts to defuse" {
    var field = empty_field(1, 1);
    field.grid.put(0, .{ .tiered = .red });

    const first = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(c.SlimeCell{ .tiered = .yellow }, field.grid.get(0));
    try testing.expectEqual(@as(u16, 0), first.neutralized);

    _ = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.get(0));

    const third = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.get(0));
    try testing.expectEqual(@as(u16, 1), third.neutralized);
    try testing.expectEqual(@as(u16, 1), third.downgraded[ti(.green)]);

    // A fourth cast finds nothing left to neutralize.
    const fourth = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(@as(u16, 0), fourth.total_downgraded());
    try testing.expectEqual(@as(u16, 1), fourth.inert);
}

test "apply_shape clips at the grid edge and reports the loss" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .green });

    // Anchored at the top-left corner, a 3x3 lands only its bottom-right
    // quadrant: 4 cells on, 5 offsets clipped away.
    const out = field.apply_shape(SQUARE_3X3, 0, 0);
    try testing.expectEqual(@as(u16, 4), out.total_downgraded());
    try testing.expectEqual(@as(u16, 5), out.off_grid);
    try testing.expectEqual(@as(u16, 0), out.inert);
    try testing.expectEqual(@as(u16, 5), out.wasted());
    try testing.expectEqual(@as(u16, 4), out.neutralized);

    // Exactly the 2x2 block around the anchor was defused.
    for (0..3) |r| {
        for (0..3) |cl| {
            const expect_defused = r <= 1 and cl <= 1;
            const cell = field.grid.at(@intCast(r), @intCast(cl));
            try testing.expectEqual(expect_defused, cell == .neutralized);
        }
    }
}

test "apply_shape counts inert cells but leaves them untouched" {
    var field = empty_field(1, 3);
    field.grid.put(0, .neutral);
    field.grid.put(1, .neutralized);
    field.grid.put(2, .empty);

    const out = field.apply_shape(test_shape(&.{"###"}), 0, 1);
    try testing.expectEqual(@as(u16, 0), out.total_downgraded());
    try testing.expectEqual(@as(u16, 3), out.inert);
    try testing.expectEqual(@as(u16, 0), out.off_grid);
    // Untouched: neutral stays neutral, defused stays defused, empty stays empty.
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.get(0));
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.get(1));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.get(2));
}

test "apply_shape hits exactly the shape's footprint" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .green });

    const out = field.apply_shape(PLUS, 1, 1);
    try testing.expectEqual(@as(u16, 5), out.total_downgraded());
    // The four diagonals are untouched; the plus arms are defused.
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.at(0, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.at(0, 2));
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.at(2, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.at(2, 2));
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.at(0, 1));
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.at(1, 1));
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.at(1, 2));
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.at(2, 1));
}

test "apply_shape destroys nothing: the unit count is unchanged" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .red });
    const before = field.remaining();

    _ = field.apply_shape(SQUARE_3X3, 1, 1);
    _ = field.apply_shape(SQUARE_3X3, 1, 1);
    _ = field.apply_shape(SQUARE_3X3, 1, 1);

    // Every cell is defused, and every unit is still there to be eaten.
    try testing.expectEqual(before, field.remaining());
    try testing.expectEqual(@as(u16, 9), field.grid.occupied());
    try testing.expectEqual(@as(u16, 0), field.grid.hazard_count());
}

test "apply_shape is deterministic — the same aim gives the same field" {
    const run = struct {
        fn go() SlimeField {
            var field = empty_field(4, 4);
            paint(&field, .{ .tiered = .red });
            _ = field.apply_shape(PLUS, 2, 2);
            return field;
        }
    }.go;
    const a = run();
    const b = run();
    try testing.expectEqualSlices(c.SlimeCell, a.grid.live(), b.grid.live());
}

test "feast consumes every edible unit in the bitten columns and no more" {
    var field = empty_field(2, 3);
    field.grid.set(0, 0, .neutral);
    field.grid.set(1, 0, .neutralized);
    field.grid.set(0, 1, .neutral);
    field.grid.set(1, 2, .neutral);

    const out = field.feast(test_bal, 1);
    // Column 0 is eaten whole; columns 1 and 2 are out of the bite.
    try testing.expectEqual(@as(u16, 2), out.cells);
    try testing.expectEqual(@as(u16, 1), out.neutral);
    try testing.expectEqual(@as(u16, 1), out.defused);
    try testing.expectEqual(2 * test_bal.hunger_cost_normal, out.hunger);
    try testing.expectEqual(@as(u32, 2), out.score);
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 0));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(0, 1));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(1, 2));
}

test "feast width is the column count and clamps at the grid" {
    var field = empty_field(1, 3);
    paint(&field, .neutral);

    const two = field.feast(test_bal, 2);
    try testing.expectEqual(@as(u16, 2), two.cells);
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.get(2));

    // A width past the grid's edge just means "the whole board".
    const rest = field.feast(test_bal, 99);
    try testing.expectEqual(@as(u16, 1), rest.cells);
    try testing.expect(field.is_exhausted());
}

test "a live hazard is NIBBLED: one downgrade in place, hunger, no score" {
    var field = empty_field(1, 2);
    field.grid.put(0, .{ .tiered = .red });
    field.grid.put(1, .neutral);

    const out = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 0), out.cells);
    try testing.expectEqual(@as(u32, 0), out.score);
    try testing.expectEqual(test_bal.hunger_cost_normal, out.hunger);
    try testing.expectEqual(@as(u16, 1), out.bitten_downgraded[ti(.red)]);
    try testing.expectEqual(@as(u16, 1), out.total_bitten());
    try testing.expectEqual(@as(u16, 0), out.bitten_defused);
    // The survivor stays in place, one tier softer; its neighbour is out of
    // the bite and untouched.
    try testing.expectEqual(c.SlimeCell{ .tiered = .yellow }, field.grid.get(0));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.get(1));
}

test "four bites eat a red: three nibbles defuse it, the fourth consumes it" {
    var field = empty_field(1, 1);
    field.grid.put(0, .{ .tiered = .red });

    const first = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 1), first.bitten_downgraded[ti(.red)]);
    try testing.expectEqual(c.SlimeCell{ .tiered = .yellow }, field.grid.get(0));

    const second = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 1), second.bitten_downgraded[ti(.yellow)]);
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.get(0));

    const third = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 1), third.bitten_downgraded[ti(.green)]);
    try testing.expectEqual(@as(u16, 1), third.bitten_defused);
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.get(0));
    // Three nibbles so far: hunger every time, score never.
    try testing.expectEqual(@as(u32, 0), first.score + second.score + third.score);

    const fourth = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 1), fourth.cells);
    try testing.expectEqual(@as(u16, 1), fourth.defused);
    try testing.expectEqual(@as(u32, 1), fourth.score);
    try testing.expect(field.is_exhausted());
}

test "a neutralizer is consumed for FREE: no score, no hunger" {
    var field = empty_field(3, 1);
    field.grid.set(0, 0, .neutral);
    field.grid.set(1, 0, .{ .special = .neutralizer });
    field.grid.set(2, 0, .neutral);

    const out = field.feast(test_bal, 1);
    // Everything goes, but only the two neutrals are FOOD.
    try testing.expectEqual(@as(u16, 3), out.cells);
    try testing.expectEqual(@as(u32, 2), out.score);
    try testing.expectEqual(2 * test_bal.hunger_cost_normal, out.hunger);
    try testing.expectEqual(@as(u16, 1), out.agents);
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(1, 0));
    try testing.expect(field.is_exhausted());
}

test "an eaten neutralizer fires a 3x3 Agent block on the standing board" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .red });
    field.grid.set(1, 0, .{ .special = .neutralizer });

    const out = field.feast(test_bal, 1);
    // The bite walks column 0 top-down: (0,0) is nibbled red->yellow BEFORE
    // the neutralizer at (1,0) fires; the block then covers rows 0-2, cols
    // 0-1 — the fresh yellow steps to green, four reds step to yellow — and
    // the walk finishes on (2,0), nibbling the new yellow to green.
    try testing.expectEqual(@as(u16, 1), out.agents);
    try testing.expectEqual(@as(u16, 1), out.cells);
    try testing.expectEqual(@as(u32, 0), out.score);
    // Two nibbles paid hunger; the neutralizer itself was free.
    try testing.expectEqual(2 * test_bal.hunger_cost_normal, out.hunger);
    try testing.expectEqual(@as(u16, 1), out.bitten_downgraded[ti(.red)]);
    try testing.expectEqual(@as(u16, 1), out.bitten_downgraded[ti(.yellow)]);
    try testing.expectEqual(@as(u16, 4), out.agent_downgraded[ti(.red)]);
    try testing.expectEqual(@as(u16, 1), out.agent_downgraded[ti(.yellow)]);
    try testing.expectEqual(@as(u16, 0), out.agent_defused);
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.at(0, 0));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.at(2, 0));
    // Column 2 was outside both the bite and the block: still red.
    try testing.expectEqual(@as(u16, 3), field.grid.tier_count(.red));
}

test "the Agent block defuses a cell LATER IN THE SAME BITE, which is then consumed" {
    // Inline cascade in miniature: the neutralizer at the top of the column
    // defuses the green below it before the walk arrives there.
    var field = empty_field(2, 1);
    field.grid.set(0, 0, .{ .special = .neutralizer });
    field.grid.set(1, 0, .{ .tiered = .green });

    const out = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 2), out.cells);
    try testing.expectEqual(@as(u16, 1), out.agents);
    try testing.expectEqual(@as(u16, 1), out.agent_defused);
    try testing.expectEqual(@as(u16, 1), out.defused);
    try testing.expectEqual(@as(u32, 1), out.score);
    try testing.expectEqual(@as(u16, 0), out.total_bitten());
    try testing.expect(field.is_exhausted());
}

test "a hazard bitten BEFORE a later neutralizer fires is nibbled, not saved" {
    // Order matters and is the contract: the walk is top-down, so a green
    // ABOVE the neutralizer is nibbled to neutralized before the block
    // lands (which then finds nothing left to downgrade there).
    var field = empty_field(2, 1);
    field.grid.set(0, 0, .{ .tiered = .green });
    field.grid.set(1, 0, .{ .special = .neutralizer });

    const out = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 1), out.cells); // the neutralizer alone
    try testing.expectEqual(@as(u16, 1), out.bitten_downgraded[ti(.green)]);
    try testing.expectEqual(@as(u16, 1), out.bitten_defused);
    try testing.expectEqual(@as(u32, 0), out.score);
    // Defused by the nibble, it survives the turn as food for the next one.
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.at(0, 0));
}

test "a consumable special is food: eaten, scored, and hatched" {
    var field = empty_field(3, 1);
    field.grid.set(0, 0, .neutral);
    field.grid.set(1, 0, .{ .special = .egg });
    field.grid.set(2, 0, .neutral);

    const out = field.feast(test_bal, 1);
    // Normal price, normal score — the hatch is the bonus.
    try testing.expectEqual(@as(u16, 3), out.cells);
    try testing.expectEqual(3 * test_bal.hunger_cost_normal, out.hunger);
    try testing.expectEqual(@as(u32, 3), out.score);
    try testing.expectEqual(@as(u16, 1), out.hatched);
    try testing.expectEqual(field.grid.index(1, 0), out.hatched_cells[0]);
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(1, 0));
    try testing.expect(field.is_exhausted());
}

test "no cast can ever change a special — except the rock, which BREAKS" {
    for ([_]c.SpecialKind{ .neutralizer, .egg, .canister, .bomb }) |kind| {
        var field = empty_field(1, 1);
        field.grid.put(0, .{ .special = kind });
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const out = field.apply_shape(DOT, 0, 0);
            try testing.expectEqual(@as(u16, 0), out.total_downgraded());
            try testing.expectEqual(@as(u16, 0), out.rocks_broken);
            try testing.expectEqual(@as(u16, 1), out.inert);
        }
        try testing.expectEqual(c.SlimeCell{ .special = kind }, field.grid.get(0));
    }
}

test "the Agent breaks a rock into red: four applications from edible" {
    var field = empty_field(1, 1);
    field.grid.put(0, .{ .special = .rock });

    // Application 1: the BREAK.  Its own tally — not a downgrade (the rock
    // had no tier to step down from), and not waste.
    const broke = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(@as(u16, 1), broke.rocks_broken);
    try testing.expectEqual(@as(u16, 0), broke.total_downgraded());
    try testing.expectEqual(@as(u16, 0), broke.wasted());
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.get(0));

    // Applications 2-4: ordinary hazard from here — red -> yellow -> green
    // -> neutralized — and then the bite eats the result.
    _ = field.apply_shape(DOT, 0, 0);
    _ = field.apply_shape(DOT, 0, 0);
    const defused = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(@as(u16, 1), defused.neutralized);
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.get(0));

    const out = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 1), out.cells);
    try testing.expectEqual(@as(u32, 1), out.score);
    try testing.expect(field.is_exhausted());
}

test "a swallowed neutralizer breaks a rock later in the same bite" {
    // Column of neutralizer / rock.  The 3x3 fires INLINE where the
    // neutralizer is eaten, cracking the rock to red BEFORE the walk gets
    // there — so the walk NIBBLES the fresh red instead of skipping a rock.
    // Part of the ordering contract the browser replay mirrors.
    var field = empty_field(2, 1);
    field.grid.set(0, 0, .{ .special = .neutralizer });
    field.grid.set(1, 0, .{ .special = .rock });

    const out = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 1), out.agents);
    try testing.expectEqual(@as(u16, 1), out.agent_rocks_broken);
    try testing.expectEqual(
        @as(u16, 1),
        out.bitten_downgraded[@intFromEnum(c.Tier.red)],
    );
    try testing.expectEqual(c.SlimeCell{ .tiered = .yellow }, field.grid.at(1, 0));
}

test "a defused front is consumed instead of nibbled: casts pre-chew the bite" {
    // The turn loop in miniature: unbitten, the green would only be nibbled;
    // one cast defuses it in time and the bite consumes it for a point.
    var field = empty_field(1, 2);
    field.grid.put(0, .{ .tiered = .green });
    field.grid.put(1, .neutral);

    _ = field.apply_shape(DOT, 0, 0);
    const out = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 1), out.cells);
    try testing.expectEqual(@as(u16, 1), out.defused);
    try testing.expectEqual(@as(u32, 1), out.score);
    try testing.expectEqual(@as(u16, 0), out.total_bitten());
}

test "empty cells in the bite are skipped for free" {
    var field = empty_field(3, 1);
    field.grid.set(1, 0, .neutral);

    const out = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 1), out.cells);
    try testing.expectEqual(test_bal.hunger_cost_normal, out.hunger);

    const none = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 0), none.cells);
    try testing.expectEqual(@as(u32, 0), none.hunger_total());
    try testing.expectEqual(@as(u32, 0), none.score);
    try testing.expectEqual(@as(u16, 0), none.total_bitten());
}

test "every consumed unit costs the same flat hunger" {
    // Difficulty decides how many bites a unit needs, not what it costs to
    // eat: consumed or nibbled, one bite is one hunger.
    for ([_]c.SlimeCell{ .neutral, .neutralized }) |cell| {
        var field = empty_field(1, 1);
        field.grid.put(0, cell);
        const out = field.feast(test_bal, 1);
        try testing.expectEqual(test_bal.hunger_cost_normal, out.hunger_total());
        try testing.expectEqual(@as(u32, 1), out.score);
    }
}

test "shift_left packs survivors against the left edge, preserving row order" {
    var field = empty_field(1, 4);
    field.grid.put(0, .empty);
    field.grid.put(1, .neutral);
    field.grid.put(2, .empty);
    field.grid.put(3, .{ .tiered = .red });

    const moved = field.shift_left();
    try testing.expectEqual(@as(u16, 2), moved);
    // Order left-to-right is preserved: neutral was ahead of the red, still is.
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(0, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(0, 1));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 2));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 3));
}

test "shift_left is per-row: slime never changes lane" {
    var field = empty_field(2, 2);
    field.grid.set(0, 0, .empty);
    field.grid.set(0, 1, .empty);
    field.grid.set(1, 0, .empty);
    field.grid.set(1, 1, .neutral);

    _ = field.shift_left();
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 0));
}

test "shift_left on a packed row moves nothing and is idempotent" {
    var field = empty_field(3, 2);
    paint(&field, .neutral);
    try testing.expectEqual(@as(u16, 0), field.shift_left());

    var field2 = empty_field(1, 3);
    field2.grid.put(1, .neutral);
    _ = field2.shift_left();
    const snapshot = field2.grid;
    try testing.expectEqual(@as(u16, 0), field2.shift_left());
    try testing.expectEqualSlices(c.SlimeCell, snapshot.live(), field2.grid.live());
}

test "shift_left conserves every unit" {
    var rng = prng(21);
    var res = c.SlimeReservoir{ .neutral = 6, .special = .{ 1, 1, 0, 0, 0 } };
    res.tiered[ti(.red)] = 4;
    var field = SlimeField.init(.{ .rows = 4, .cols = 3 }, res, test_bal, rng.random());
    _ = field.feast(test_bal, 1);
    const before = field.grid.occupied();
    _ = field.shift_left();
    try testing.expectEqual(before, field.grid.occupied());
}

test "turn settlement is bite, slide, refill from the right: the conveyor advances" {
    //   n = neutral   R = live red   . = empty
    //        col0 col1 col2
    //   row0   n    R    .
    //   row1   R    n    n
    var field = empty_field(2, 3);
    field.grid.set(0, 0, .neutral);
    field.grid.set(0, 1, .{ .tiered = .red });
    field.grid.set(1, 0, .{ .tiered = .red });
    field.grid.set(1, 1, .neutral);
    field.grid.set(1, 2, .neutral);
    field.reservoir.neutral = 2;

    const out = field.feast(test_bal, 1);
    // The bite: (0,0) consumed, (1,0) nibbled red->yellow.
    try testing.expectEqual(@as(u16, 1), out.cells);
    try testing.expectEqual(@as(u16, 1), out.bitten_downgraded[ti(.red)]);

    // The slide: each row packs left — the red slides into row 0's front,
    // the yellow survivor holds row 1's.
    _ = field.shift_left();
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(0, 0));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 1));
    try testing.expectEqual(c.SlimeCell{ .tiered = .yellow }, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(1, 1));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(1, 2));

    // The refill: both units land in the rightmost open cells.
    var rng = prng(5);
    try testing.expectEqual(@as(u16, 2), field.fill(test_bal, rng.random()));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(0, 2));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(0, 1));
}

test "a rock is INERT by default: the bite skips it — no hunger, no score" {
    var field = empty_field(3, 1);
    field.grid.set(0, 0, .neutral);
    field.grid.set(1, 0, .{ .special = .rock });
    field.grid.set(2, 0, .neutral);

    const out = field.feast(test_bal, 1);
    // Both neutrals are eaten around it; the rock costs and yields nothing.
    try testing.expectEqual(@as(u16, 2), out.cells);
    try testing.expectEqual(2 * test_bal.hunger_cost_normal, out.hunger);
    try testing.expectEqual(@as(u16, 0), out.total_bitten());
    try testing.expectEqual(@as(u16, 0), out.gnawed);
    try testing.expectEqual(c.SlimeCell{ .special = .rock }, field.grid.at(1, 0));
}

test "bite_costs_hunger: the bite GNAWS a rock — hunger, no score, no change" {
    var bal = fixtures.test_config.balance;
    bal.specials[@intFromEnum(c.SpecialKind.rock)].bite_costs_hunger = true;

    var field = empty_field(3, 1);
    field.grid.set(0, 0, .neutral);
    field.grid.set(1, 0, .{ .special = .rock });
    field.grid.set(2, 0, .neutral);

    const out = field.feast(&bal, 1);
    // The two neutrals are still eaten; the rock now costs a third mouthful
    // of hunger while yielding nothing and staying exactly where it is.
    try testing.expectEqual(@as(u16, 2), out.cells);
    try testing.expectEqual(@as(u16, 1), out.gnawed);
    try testing.expectEqual(3 * test_bal.hunger_cost_normal, out.hunger);
    try testing.expectEqual(c.SlimeCell{ .special = .rock }, field.grid.at(1, 0));

    // A gnaw is NOT a nibble: it moves nothing down a tier, so it stays out
    // of the bitten counters that drive the team's "front reached us hot"
    // feedback.
    try testing.expectEqual(@as(u16, 0), out.total_bitten());

    // Differential against the same board with the flag off: the ONLY thing
    // the flag changes is hunger — exactly one extra mouthful, for the one
    // rock.  Score is untouched, so a gnaw is pure waste and never pay.
    var plain = empty_field(3, 1);
    plain.grid.set(0, 0, .neutral);
    plain.grid.set(1, 0, .{ .special = .rock });
    plain.grid.set(2, 0, .neutral);
    const off = plain.feast(test_bal, 1);

    try testing.expectEqual(off.score, out.score);
    try testing.expectEqual(off.cells, out.cells);
    try testing.expectEqual(off.hunger + test_bal.hunger_cost_normal, out.hunger);
}

test "bite_costs_hunger is ignored for kinds the bite can swallow" {
    // The flag lives on every kind's tuning but only inconsumable ones ever
    // reach the gnaw: a consumable is eaten first, on its own terms.  Set it
    // on the canister — free equipment — and it stays free.
    var bal = fixtures.test_config.balance;
    bal.specials[@intFromEnum(c.SpecialKind.canister)].bite_costs_hunger = true;

    var field = empty_field(1, 1);
    field.grid.set(0, 0, .{ .special = .canister });

    const out = field.feast(&bal, 1);
    try testing.expectEqual(@as(u16, 1), out.cells);
    try testing.expectEqual(@as(u16, 0), out.gnawed);
    try testing.expectEqual(@as(u32, 0), out.hunger);
}

test "bite_costs_hunger: an EMPTY cell is never gnawed" {
    // Both empties and rocks fail `is_edible`, and only the rock may be
    // charged for: an empty column must stay free or an eaten-out board
    // would run the clock by itself.
    var bal = fixtures.test_config.balance;
    bal.specials[@intFromEnum(c.SpecialKind.rock)].bite_costs_hunger = true;

    var field = empty_field(3, 1); // all empty
    const out = field.feast(&bal, 1);
    try testing.expectEqual(@as(u16, 0), out.gnawed);
    try testing.expectEqual(@as(u32, 0), out.hunger);
}

test "a field holding only rocks is NOT won: rocks are clearable and owed" {
    var field = empty_field(1, 2);
    field.grid.put(0, .neutral);
    field.grid.put(1, .{ .special = .rock });
    try testing.expect(!field.is_exhausted());

    const out = field.feast(test_bal, 2);
    try testing.expectEqual(@as(u16, 1), out.cells);
    // The rock remains, and it HOLDS the win: the Agent can break it into
    // slime, so the team is expected to — the win is eating everything.
    try testing.expectEqual(@as(u16, 1), field.grid.occupied());
    try testing.expect(!field.is_exhausted());

    // Break it, chew it down, eat it: now the field is won.
    _ = field.apply_shape(DOT, 0, 1); // rock -> red
    _ = field.apply_shape(DOT, 0, 1); // red -> yellow
    _ = field.apply_shape(DOT, 0, 1); // yellow -> green
    _ = field.apply_shape(DOT, 0, 1); // green -> neutralized
    _ = field.shift_left();
    const meal = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 1), meal.cells);
    try testing.expect(field.is_exhausted());
}

test "a rocks-only field STALLS by default, and bite_costs_hunger ends it" {
    // The counterpart to the win above, and the reason session.check_end's
    // "the game always moves" invariant now needs the Agent to hold.
    //
    // A rock is skipped by the bite: no hunger, no score, no change.  So a
    // field of nothing but rocks is inert under biting alone — it is neither
    // exhausted (rocks are owed) nor advancing toward the hunger bar.  Only a
    // cast breaks the stall, which is why a team that can still afford one
    // always has a move, and why a team that cannot has none.
    var field = empty_field(1, 2);
    field.grid.put(0, .{ .special = .rock });
    field.grid.put(1, .{ .special = .rock });

    // Bite it as often as you like: nothing is eaten, nothing is nibbled and
    // — the part that matters — no hunger accrues, so the clock never runs.
    for (0..8) |_| {
        const out = field.feast(test_bal, 2);
        try testing.expectEqual(@as(u16, 0), out.cells);
        try testing.expectEqual([_]u16{ 0, 0, 0 }, out.bitten_downgraded);
        try testing.expectEqual(@as(u32, 0), out.hunger);
        _ = field.shift_left();
    }
    try testing.expectEqual(@as(u16, 2), field.grid.occupied());
    try testing.expect(!field.is_exhausted());

    // The Agent is the only thing that moves it — and it costs charges.
    _ = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(0, 0));

    // With `bite_costs_hunger` on, the same board is no longer a stall.  The
    // rocks still cannot be eaten, downgraded or moved by the bite — the
    // board is as frozen as before — but every bite now fills hunger, so the
    // clock runs and the encounter reaches `hunger_full` on its own.  This is
    // the knob that restores check_end's "the game always moves" without
    // making a rock breakable by teeth.
    var bal = fixtures.test_config.balance;
    bal.specials[@intFromEnum(c.SpecialKind.rock)].bite_costs_hunger = true;

    var stone = empty_field(1, 2);
    stone.grid.put(0, .{ .special = .rock });
    stone.grid.put(1, .{ .special = .rock });

    var total: u32 = 0;
    for (0..8) |_| {
        const out = stone.feast(&bal, 2);
        try testing.expectEqual(@as(u16, 2), out.gnawed); // both, every bite
        try testing.expectEqual(@as(u16, 0), out.cells);
        try testing.expectEqual([_]u16{ 0, 0, 0 }, out.bitten_downgraded);
        total += out.hunger;
        _ = stone.shift_left();
    }
    try testing.expectEqual(16 * test_bal.hunger_cost_normal, total);
    // Still owed, still unbroken — the flag buys an ENDING, not progress.
    try testing.expectEqual(@as(u16, 2), stone.grid.occupied());
    try testing.expect(!stone.is_exhausted());
}

test "a rock rides the conveyor like any unit" {
    var field = empty_field(1, 3);
    field.grid.set(0, 2, .{ .special = .rock });

    try testing.expectEqual(@as(u16, 1), field.shift_left());
    try testing.expectEqual(c.SlimeCell{ .special = .rock }, field.grid.at(0, 0));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 2));
}

test "a canister is free equipment that refills charge_refill per swallow" {
    var field = empty_field(4, 1);
    field.grid.set(0, 0, .neutral);
    field.grid.set(1, 0, .{ .special = .canister });
    field.grid.set(2, 0, .{ .special = .canister });
    field.grid.set(3, 0, .neutral);

    const out = field.feast(test_bal, 1);
    // All four eaten, but only the two neutrals are FOOD: canisters score
    // nothing, cost no hunger, and pour their agent energy back into the
    // pool.
    try testing.expectEqual(@as(u16, 4), out.cells);
    try testing.expectEqual(@as(u32, 2), out.score);
    try testing.expectEqual(2 * test_bal.hunger_cost_normal, out.hunger);
    try testing.expectEqual(@as(u16, 2), out.canisters);
    try testing.expectEqual(
        2 * @as(u32, test_bal.special_tuning(.canister).charge_refill),
        out.charges_refilled,
    );
    try testing.expect(field.is_exhausted());
}

test "a bomb levels its 3x3: everything around it is DESTROYED, not eaten" {
    //   col: 0 1 2
    //   r0:  n R n
    //   r1:  B R n
    //   r2:  n R n
    // A two-column bite: the bomb at (1,0) blows its 3x3 — the neutrals
    // above and below it, and the red column — out of play; the crater
    // cells the walk reaches afterwards are simply empty.
    var field = empty_field(3, 3);
    field.grid.set(0, 0, .neutral);
    field.grid.set(1, 0, .{ .special = .bomb });
    field.grid.set(2, 0, .neutral);
    var row: u8 = 0;
    while (row < 3) : (row += 1) {
        field.grid.set(row, 1, .{ .tiered = .red });
        field.grid.set(row, 2, .neutral);
    }

    const out = field.feast(test_bal, 2);
    try testing.expectEqual(@as(u16, 1), out.bombs);
    // Consumed before the blast: (0,0).  Destroyed by it: (2,0) and the
    // three reds — removed outright, no score, no hunger, no nibbles.
    try testing.expectEqual(@as(u16, 4), out.destroyed);
    // Eaten: (0,0) and the bomb (free).
    try testing.expectEqual(@as(u16, 2), out.cells);
    try testing.expectEqual(@as(u32, 1), out.score);
    try testing.expectEqual(1 * test_bal.hunger_cost_normal, out.hunger);
    try testing.expectEqual(@as(u16, 0), out.total_bitten());
    // Column 2 was outside the bite: untouched.
    try testing.expectEqual(@as(u16, 3), field.grid.occupied());
}

test "explode_rocks_only: the blast destroys rocks and spares everything else" {
    var bal = fixtures.test_config.balance;
    bal.specials[@intFromEnum(c.SpecialKind.bomb)].explode_rocks_only = true;

    // Column of n / B / K (K = rock, inside the bomb's 3x3): the rock is
    // blown out of play — the one way to remove one.
    var field = empty_field(3, 1);
    field.grid.set(0, 0, .neutral);
    field.grid.set(1, 0, .{ .special = .bomb });
    field.grid.set(2, 0, .{ .special = .rock });

    const out = field.feast(&bal, 1);
    try testing.expectEqual(@as(u16, 1), out.bombs);
    try testing.expectEqual(@as(u16, 1), out.destroyed); // the rock alone
    try testing.expectEqual(@as(u16, 2), out.cells); // the neutral + bomb
    try testing.expectEqual(@as(u32, 1), out.score);
    try testing.expectEqual(@as(u16, 0), field.grid.occupied());
    try testing.expect(field.is_exhausted());

    // n / B / R under the same tuning: the live red is IN the blast but is
    // NOT a rock, so it survives the blast — and the bite then nibbles it.
    // (Default tuning would have levelled it: see the 3x3 bomb test.)
    var spared = empty_field(3, 1);
    spared.grid.set(0, 0, .neutral);
    spared.grid.set(1, 0, .{ .special = .bomb });
    spared.grid.set(2, 0, .{ .tiered = .red });

    const held = spared.feast(&bal, 1);
    try testing.expectEqual(@as(u16, 1), held.bombs);
    try testing.expectEqual(@as(u16, 0), held.destroyed);
    try testing.expectEqual(@as(u16, 2), held.cells); // the neutral + bomb
    try testing.expectEqual(@as(u16, 1), held.bitten_downgraded[ti(.red)]);
    try testing.expectEqual(c.SlimeCell{ .tiered = .yellow }, spared.grid.at(2, 0));
}

test "neutralizers are playable slime: the win requires eating them too" {
    var field = empty_field(2, 1);
    field.grid.set(0, 0, .neutral);
    field.grid.set(1, 0, .{ .special = .neutralizer });
    try testing.expect(!field.is_exhausted());

    // Both are consumed by one bite — the neutralizer for free — and only
    // then is the field spent.
    const out = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 2), out.cells);
    try testing.expectEqual(@as(u32, 1), out.score);
    try testing.expectEqual(@as(u16, 0), field.grid.occupied());
    try testing.expect(field.is_exhausted());
}

test "an uneaten egg keeps the field unwon: eggs are playable slime" {
    var field = empty_field(1, 2);
    field.grid.put(0, .{ .tiered = .red });
    field.grid.put(1, .{ .special = .egg });

    // The bite only nibbles the red; the egg behind it is out of this
    // turn's bite and still on the grid — food the team has not eaten, so
    // no win.  Both still count: each can be cleared.
    const out = field.feast(test_bal, 1);
    try testing.expectEqual(@as(u16, 0), out.cells);
    try testing.expectEqual(@as(u32, 2), field.remaining());
    try testing.expect(!field.is_exhausted());
}

test "turn after turn, the conveyor feeds every unit even without casts" {
    // Liveness: nibbles alone defuse every hazard eventually, so the bite
    // clears the whole supply with NO casts at all — running out of charges
    // can never stall the game, only slow it.
    var rng = prng(14);
    var res = c.SlimeReservoir{ .neutral = 7 };
    res.tiered[ti(.red)] = 6;
    res.tiered[ti(.green)] = 4;
    const total_units = res.total();
    var field = SlimeField.init(.{ .rows = 3, .cols = 3 }, res, test_bal, rng.random());

    var eaten: u32 = 0;
    var hunger: u32 = 0;
    var score: u32 = 0;
    var turns: u32 = 0;
    while (!field.is_exhausted() and turns < 500) : (turns += 1) {
        const out = field.feast(test_bal, 1);
        eaten += out.cells;
        hunger += out.hunger_total();
        score += out.score;
        _ = field.shift_left();
        _ = field.fill(test_bal, rng.random());
    }

    try testing.expect(field.is_exhausted());
    try testing.expectEqual(total_units, eaten);
    // Every unit scored when it was finally consumed...
    try testing.expectEqual(total_units, score);
    // ...but the nibbles that softened the hazards each cost hunger too:
    // a red takes 3 nibbles, a green 1, on top of the consuming bite.
    const nibbles: u32 = 6 * 3 + 4 * 1;
    try testing.expectEqual(
        (total_units + nibbles) * test_bal.hunger_cost_normal,
        hunger,
    );
}

test "leaving hazards up wastes hunger on nibbles that score nothing" {
    var rng = prng(9);
    var res = c.SlimeReservoir{ .neutral = 4 };
    res.tiered[ti(.red)] = 5;
    var field = SlimeField.init(.{ .rows = 3, .cols = 3 }, res, test_bal, rng.random());

    const out = field.feast(test_bal, 3);
    // Every bite paid the flat rate: consumed food scored, nibbles did not.
    try testing.expectEqual(
        (@as(u32, out.cells) + out.total_bitten()) * test_bal.hunger_cost_normal,
        out.hunger_total(),
    );
    try testing.expectEqual(@as(u32, out.cells), out.score);
    // A 3x3 grid holding 9 units, all bitten: the 4 neutrals were consumed
    // and every red was nibbled one step to yellow.
    try testing.expectEqual(@as(u16, 4), out.cells);
    try testing.expectEqual(@as(u16, 5), out.bitten_downgraded[ti(.red)]);
    try testing.expectEqual(@as(u16, 5), field.grid.tier_count(.yellow));
}

test "defusing before the bite turns nibbles into points" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .green });

    // One cast over the whole 3x3 defuses all nine, so a whole-board bite
    // consumes all nine.
    _ = field.apply_shape(SQUARE_3X3, 1, 1);

    const out = field.feast(test_bal, 3);
    try testing.expectEqual(@as(u16, 9), out.cells);
    try testing.expectEqual(@as(u32, 9), out.score);
    try testing.expectEqual(@as(u16, 0), out.total_bitten());
    try testing.expectEqual(9 * test_bal.hunger_cost_normal, out.hunger_total());
}

test "field ops are reproducible for a given seed" {
    const run = struct {
        fn go(seed: u64) SlimeField {
            var rng = prng(seed);
            var res = c.SlimeReservoir{ .neutral = 10 };
            res.tiered[ti(.red)] = 10;
            var field = SlimeField.init(.{ .rows = 3, .cols = 4 }, res, test_bal, rng.random());
            _ = field.apply_shape(PLUS, 1, 1);
            _ = field.feast(test_bal, 2);
            _ = field.shift_left();
            _ = field.fill(test_bal, rng.random());
            return field;
        }
    }.go;

    const a = run(42);
    const b = run(42);
    try testing.expectEqualSlices(c.SlimeCell, a.grid.live(), b.grid.live());
    try testing.expectEqual(a.reservoir, b.reservoir);
}

test "eggs draw from the reservoir like any other unit" {
    // Door avoidance off so every cell is eligible: this test is about the
    // DRAW mixing kinds proportionally, not about spawn restrictions.
    var bal = fixtures.test_config.balance;
    bal.specials_avoid_door_column = false;

    var rng = prng(23);
    var res = c.SlimeReservoir{ .neutral = 2 };
    res.special[@intFromEnum(c.SpecialKind.egg)] = 2;
    res.special[@intFromEnum(c.SpecialKind.neutralizer)] = 2;
    const field = SlimeField.init(.{ .rows = 2, .cols = 3 }, res, &bal, rng.random());

    // Composition preserved exactly; only placement is random.
    try testing.expectEqual(@as(u16, 6), field.grid.occupied());
    try testing.expect(field.reservoir.is_empty());
    try testing.expectEqual(@as(u16, 2), field.grid.special_kind_count(.egg));
    try testing.expectEqual(@as(u16, 2), field.grid.special_kind_count(.neutralizer));
}

test "match machinery is DORMANT: lined-up specials never pop" {
    // The detection/pop/5x5 pipeline is kept for a future matchable kind,
    // but no current kind matches — a perfect line survives resolve_matches
    // untouched, rows and columns alike.
    var field = empty_field(5, 5);
    field.grid.set(2, 1, .{ .special = .neutralizer });
    field.grid.set(2, 2, .{ .special = .neutralizer });
    field.grid.set(2, 3, .{ .special = .neutralizer });
    field.grid.set(0, 0, .{ .special = .egg });
    field.grid.set(1, 0, .{ .special = .egg });
    field.grid.set(2, 0, .{ .special = .egg });

    const out = field.resolve_matches(test_bal);
    try testing.expectEqual(@as(u16, 0), out.count);
    try testing.expectEqual(@as(u16, 0), out.popped());
    try testing.expectEqual(@as(u16, 6), field.grid.special_count());

    // Even a permissive match_len changes nothing: the gate is the KIND's
    // match_effect, and every current kind returns null.
    var bal = test_bal.*;
    bal.specials[@intFromEnum(c.SpecialKind.neutralizer)].match_len = 2;
    const still = field.resolve_matches(&bal);
    try testing.expectEqual(@as(u16, 0), still.count);
}

test "runs below match_len, gapped runs, and eggs never match" {
    var field = empty_field(3, 5);
    // Two in a row: short of the default match_len of 3.
    field.grid.set(0, 0, .{ .special = .neutralizer });
    field.grid.set(0, 1, .{ .special = .neutralizer });
    // Three with a gap: two runs of 2 and 1.
    field.grid.set(1, 0, .{ .special = .neutralizer });
    field.grid.set(1, 1, .{ .special = .neutralizer });
    field.grid.set(1, 3, .{ .special = .neutralizer });
    // Three eggs in a row: consumable kinds have no match behaviour at all.
    field.grid.set(2, 0, .{ .special = .egg });
    field.grid.set(2, 1, .{ .special = .egg });
    field.grid.set(2, 2, .{ .special = .egg });

    const out = field.resolve_matches(test_bal);
    try testing.expectEqual(@as(u16, 0), out.count);
    // Nothing popped, nothing changed.
    try testing.expectEqual(@as(u16, 8), field.grid.special_count());
}

test "mixed-kind runs do not match: the line must be one kind" {
    var field = empty_field(1, 3);
    field.grid.put(0, .{ .special = .neutralizer });
    field.grid.put(1, .{ .special = .egg });
    field.grid.put(2, .{ .special = .neutralizer });
    const out = field.resolve_matches(test_bal);
    try testing.expectEqual(@as(u16, 0), out.count);
}

