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
//!   fill        — move reservoir slime into empty cells, TOP ROW FIRST
//!                 (row 0 down), each unit's type drawn from the reservoir in
//!                 proportion to what remains.
//!   apply_shape — stamp a cast's footprint at an aimed anchor, DOWNGRADING
//!                 every covered hazard one tier.  Deterministic: the player
//!                 chose the cells, so nothing is random and nothing is
//!                 destroyed — only made safer.
//!   eat_all     — the turn-end feast: eat every EDIBLE unit REACHABLE from
//!                 the left edge.  Live hazards are inedible walls; specials
//!                 are consumed on the way through — an egg HATCHES a baby
//!                 (reported, not resolved here) and a neutralizer settles
//!                 the board (COLLAPSE, then its 3x3 Agent block on the
//!                 settled cells), letting the feast re-enter and eat
//!                 straight through whatever it defused.
//!   collapse    — drop every surviving unit to the bottom of its column, so
//!                 the holes the feast made rise to the top.
//!   resolve_matches — after the refill, pop every run of `match_len`+
//!                 same-kind matchable specials in a row or column and fire
//!                 the kind's effect at the run's central cell.  DORMANT: no
//!                 current kind matches; kept for a future one.
//!
//! ## The path
//!
//! The feast is not a bulk operation over the whole grid: it enters FROM THE
//! LEFT EDGE and can only reach through cells it eats or cells that are
//! already empty.  A live hazard therefore shelters everything behind it, and
//! the strategic question of a turn becomes *which wall to open*, not merely
//! *how much slime to clean*.  Gravity NEVER interrupts an open route: a
//! contiguous path that was reachable when the feast began is eaten to the
//! end.  The board only collapses at the meal's punctuation marks — when a
//! neutralizer is swallowed (settle first, then its block fires) and when a
//! pass runs dry — and each settle can drop new food into reach, so the
//! feast resumes until a pass eats nothing or a collapse moves nothing.
//!
//! Turn-end order is `eat_all` (passes and settles interleaved) → `fill`:
//! eat until nothing reachable is edible and the board is stable, then top
//! the columns up from the reservoir.  Falling matters because it re-sorts
//! which cells touch the left edge, so a wall that sheltered slime this turn
//! may not next turn.
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

    /// Build a field of `dims` holding `total` slime: as much as fits is
    /// placed on the grid (top row first), the remainder stays in the
    /// reservoir.
    pub fn init(
        dims: balance.SlimeGridDims,
        total: c.SlimeReservoir,
        rand: std.Random,
    ) SlimeField {
        var self = SlimeField{
            .grid = c.SlimeGrid.init(dims.rows, dims.cols),
            .reservoir = total,
        };
        _ = self.fill(rand);
        return self;
    }

    /// Total slime still in play: on the grid plus in the reservoir.
    pub fn remaining(self: *const SlimeField) u32 {
        return @as(u32, self.grid.occupied()) + self.reservoir.total();
    }

    /// Slime still in play the team can actually clear — everything except
    /// INCONSUMABLE specials.  Consumable specials (eggs) count: the feast
    /// eats them like any other food.
    pub fn remaining_playable(self: *const SlimeField) u32 {
        return @as(u32, self.grid.playable_count()) + self.reservoir.playable();
    }

    /// True when nothing but inconsumable `special` units is left anywhere.
    ///
    /// This is the WIN, not "the grid is empty": an inconsumable special can
    /// only leave the grid by matching, which the team cannot force, so
    /// demanding an empty grid would make encounters unwinnable.  Clearing
    /// all the clearable slime is the achievement.
    pub fn is_exhausted(self: *const SlimeField) bool {
        return self.remaining_playable() == 0;
    }

    /// Move reservoir slime into every empty cell, walking row 0 (the top)
    /// downward so refills visibly enter from above.  Stops when the grid is
    /// full or the reservoir runs dry.  Returns the number of cells filled.
    pub fn fill(self: *SlimeField, rand: std.Random) u16 {
        var filled: u16 = 0;
        var flat: u16 = 0;
        const n = self.grid.len();
        while (flat < n) : (flat += 1) {
            if (self.grid.get(flat).is_slime()) continue;
            const cell = self.take_from_reservoir(rand) orelse break;
            self.grid.put(flat, cell);
            filled += 1;
        }
        return filled;
    }

    /// Draw one unit from the reservoir, chosen uniformly among the units
    /// remaining (so the grid mixes in proportion to the reservoir's
    /// composition).  Returns null when the reservoir is empty.
    fn take_from_reservoir(self: *SlimeField, rand: std.Random) ?c.SlimeCell {
        const total = self.reservoir.total();
        if (total == 0) return null;

        var pick = rand.uintLessThan(u32, total);
        if (pick < self.reservoir.neutral) {
            self.reservoir.neutral -= 1;
            return .neutral;
        }
        pick -= self.reservoir.neutral;
        for (&self.reservoir.special, 0..) |*count, k| {
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
        unreachable; // `total` is the sum of the buckets just walked.
    }

    /// Stamp one cast's shape on the grid, anchored at (`row`, `col`).
    ///
    /// Every covered cell holding a hazard is DOWNGRADED one tier
    /// (red -> yellow -> green -> neutralized).  Nothing is destroyed: a
    /// neutralized unit stays on the grid, edible, scoring, and costing only
    /// normal hunger — clearing the field is the Lil Guys' job, not the cast's.
    ///
    /// Cells the shape covers that cannot be downgraded are WASTED, and the
    /// distinction is the player's aiming feedback:
    ///   - `off_grid`  — the offset fell outside the playfield (clipped)
    ///   - `inert`     — a real cell with nothing to neutralize (empty,
    ///                   neutral, already neutralized, or a `special`, which no
    ///                   cast can ever change)
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

    /// The turn-end feast: eat every EDIBLE unit the Lil Guys can REACH,
    /// one bite at a time, with the board HELD STILL between plain bites.
    ///
    /// They enter from the LEFT EDGE (column 0) and reach 4-connected through
    /// cells that conduct: empty cells and edible cells.  A live hazard is a
    /// WALL — inedible, impassable, a shelter for everything behind it.  Each
    /// bite takes the first reachable edible unit in flood order.  Gravity
    /// NEVER interrupts an open route mid-meal: a contiguous path that was
    /// reachable when a pass began is eaten to the end.
    ///
    /// Specials are consumed like anything edible: an egg is food (flat rate,
    /// scores, recorded in `hatched_cells` so the caller can hatch a baby per
    /// egg) and leaves the board where it stood; a NEUTRALIZER is free
    /// equipment — no score, no hunger — that settles the board (COLLAPSE,
    /// then EFFECT): the columns drain first, then its 3x3 Agent block fires
    /// on the settled board at the cell it was eaten from, and the feast
    /// re-enters from the left to flow through whatever it defused.  This is
    /// the whole tactical core: a cast's value is the path it opens, and
    /// slime the team cannot expose survives untouched.
    ///
    /// When nothing reachable is edible, the board collapses once; if the
    /// falls dropped new food into reach the feast resumes, and the meal only
    /// ends when a pass eats nothing or a settle moves nothing.
    ///
    /// The grid comes back COLLAPSED, with its walls and sheltered slime
    /// intact; the caller's next step is `fill`.
    ///
    /// Deterministic: no randomness, and the bite order (first edible in
    /// flood order, board settled only at neutralizers and dry passes) is
    /// part of the contract — the browser's replay and the badge's port take
    /// the identical bites.
    pub fn eat_all(self: *SlimeField, bal: *const balance.Balance) FeastOutcome {
        var out = FeastOutcome{};

        // PASSES OF BITES: eat everything reachable without collapsing, so
        // no wall can fall into an open route and plug it mid-pass.  A
        // swallowed neutralizer settles the board — collapse, THEN its 3x3
        // fires on the settled cells — and the flood re-enters; a dry pass
        // settles once more, and food that fell into reach reopens the meal.
        //
        // Terminates: a pass either eats at least one unit or ends the loop,
        // a dry-pass settle must move at least one unit to continue, and
        // nothing enters the grid mid-feast.
        feast: while (true) {
            var ate_any = false;
            while (self.next_bite()) |flat| {
                ate_any = true;
                const effect = self.consume(flat, bal, &out) orelse continue;
                switch (effect) {
                    // Recorded in `consume`; nothing on the board changes.
                    .hatch => {},
                    .neutralize_block => {
                        // Settle FIRST, then fire the 3x3 where the
                        // neutralizer was eaten — on the collapsed board —
                        // and send the flood back in from the left.
                        _ = self.collapse();
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
                        continue :feast;
                    },
                }
            }
            if (!ate_any) break;
            if (self.collapse() == 0) break;
        }

        // Everything the finished meal still cannot reach: the walls that
        // held, and the food they saved.  Counted for the players' feedback —
        // "you left N units behind a wall" is the lesson the next turn is
        // built on.
        var visited = [_]bool{false} ** c.MAX_GRID_CELLS;
        _ = self.flood(&visited, false);
        var flat: u16 = 0;
        while (flat < self.grid.len()) : (flat += 1) {
            if (visited[flat]) continue;
            const cell = self.grid.get(flat);
            if (cell.is_edible()) out.sheltered += 1;
            if (cell.blocks_feast()) out.walls += 1;
        }
        return out;
    }

    /// The next unit the feast eats: the FIRST edible cell in flood order, or
    /// null when nothing edible is reachable.  Recomputed per bite because
    /// every bite opens a cell (and a neutralizer settles the board).
    fn next_bite(self: *const SlimeField) ?u16 {
        var visited = [_]bool{false} ** c.MAX_GRID_CELLS;
        return self.flood(&visited, true);
    }

    /// Breadth-first reachability from the left edge: door cells top-down,
    /// then up/down/left/right FIFO, through anything that does not block.
    /// This visit order is part of the cross-implementation contract — the
    /// browser's replay and the badge's port walk the identical order, so
    /// every bite lands on the same cell everywhere.
    ///
    /// With `stop_at_edible`, returns the first EDIBLE cell dequeued (the
    /// next bite) or null; otherwise floods to completion and returns null,
    /// leaving `visited` as the reachable set.
    fn flood(
        self: *const SlimeField,
        visited: *[c.MAX_GRID_CELLS]bool,
        stop_at_edible: bool,
    ) ?u16 {
        // `queue` doubles as the visited marker's backing store: a cell is
        // enqueued exactly once, so the frontier can never exceed the grid.
        var queue: [c.MAX_GRID_CELLS]u16 = undefined;
        var head: u16 = 0;
        var tail: u16 = 0;

        var row: u8 = 0;
        while (row < self.grid.rows) : (row += 1) {
            const flat = self.grid.index(row, 0);
            if (self.grid.get(flat).blocks_feast()) continue; // walled at the door
            visited[flat] = true;
            queue[tail] = flat;
            tail += 1;
        }

        while (head < tail) {
            const flat = queue[head];
            head += 1;
            if (stop_at_edible and self.grid.get(flat).is_edible()) return flat;

            const r = self.grid.row_of(flat);
            const cl = self.grid.col_of(flat);
            const steps = [_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
            for (steps) |step| {
                const nr = @as(i32, r) + step[0];
                const nc = @as(i32, cl) + step[1];
                if (nr < 0 or nr >= self.grid.rows or nc < 0 or nc >= self.grid.cols) continue;
                const next = self.grid.index(@intCast(nr), @intCast(nc));
                if (visited[next]) continue;
                if (self.grid.get(next).blocks_feast()) continue;
                visited[next] = true;
                queue[tail] = next;
                tail += 1;
            }
        }
        return null;
    }

    /// Eat the edible unit at `flat`, accruing hunger and score for FOOD
    /// kinds and recording an egg's hatch.  Returns the special's on-eat
    /// effect (null for plain slime) so `eat_all` can resolve a
    /// board-changing one at the right moment: the board collapses FIRST,
    /// then the neutralizer's block fires on the settled cells.
    fn consume(
        self: *SlimeField,
        flat: u16,
        bal: *const balance.Balance,
        out: *FeastOutcome,
    ) ?c.SpecialEffect {
        const cell = self.grid.get(flat);
        switch (cell) {
            .empty => unreachable, // next_bite only returns edible cells
            .neutral => out.neutral += 1,
            .neutralized => out.defused += 1,
            .special => |kind| {
                // Only a consumable special can be reached: an inconsumable
                // one blocks_feast, and the flood never enters a blocker.
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
                    // Resolved by `eat_all` after the board settles.
                    .neutralize_block => {},
                }
                return effect;
            },
            .tiered => unreachable, // blocks_feast kept the flood out
        }
        out.cells += 1;
        out.score += 1;
        out.hunger += bal.hunger_cost_normal;
        self.grid.put(flat, .empty);
        return null;
    }

    /// Drop every surviving unit to the bottom of its column, preserving the
    /// order within the column, so the holes the feast punched rise to the top
    /// for `fill` to refill.
    ///
    /// Gravity is what keeps the field from silting up: without it, slime
    /// sheltered deep behind a wall would sit in the same cell forever and the
    /// left edge would show the same faces every turn.  Falling continually
    /// re-presents the field to the feast.
    ///
    /// Returns the number of units that moved (0 when everything already rests
    /// on the bottom).
    pub fn collapse(self: *SlimeField) u16 {
        var moved: u16 = 0;
        var col: u8 = 0;
        while (col < self.grid.cols) : (col += 1) {
            // Walk upward, packing units against the bottom: `write` is the
            // lowest cell still free to receive one.
            var write: i32 = @as(i32, self.grid.rows) - 1;
            var read: i32 = write;
            while (read >= 0) : (read -= 1) {
                const cell = self.grid.at(@intCast(read), col);
                if (!cell.is_slime()) continue;
                if (read != write) {
                    self.grid.set(@intCast(write), col, cell);
                    self.grid.set(@intCast(read), col, .empty);
                    moved += 1;
                }
                write -= 1;
            }
        }
        return moved;
    }

    /// Pop every MATCH on the grid and fire its effect.  Run once per turn,
    /// right after `fill` — the refill is what lines new specials up, so this
    /// is the moment lines can first exist.  A single pass, no cascade: holes
    /// the pops leave are tidied by the settle loop's next collapse.
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
                },
                // A hatch is an on-eat effect; no matchable kind carries it.
                .hatch => unreachable,
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
/// Hunger is a single flat rate now: only edible units are ever swallowed, so
/// there is no "ate something dangerous" penalty to account for separately.
/// The interesting numbers are the ones about the PATH — `sheltered` and
/// `walls` say why the feast stopped where it did.
pub const FeastOutcome = struct {
    /// Slime units eaten.
    cells: u16 = 0,
    /// Of those, units that were never hazardous.
    neutral: u16 = 0,
    /// Of those, units a cast had taken all the way to defused.
    defused: u16 = 0,
    /// Edible units the flood could NOT reach — food saved by a wall.  The
    /// team's main feedback: high here means the casts opened no path.
    sheltered: u16 = 0,
    /// Inedible cells (live hazards and inconsumable specials) the flood
    /// never got past.
    walls: u16 = 0,
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
    /// Hunger added: `hunger_cost_normal` per unit eaten.
    hunger: u32 = 0,
    /// Score: 1 per unit eaten (all eaten units are neutral or defused).
    score: u32 = 0,

    /// Total hunger the feast added.  Kept as a method so callers read the same
    /// way they did when hunger had several components.
    pub fn hunger_total(self: FeastOutcome) u32 {
        return self.hunger;
    }
};

/// What stamping one shape did.  The three wasted-cell kinds are kept apart
/// because they mean different things to the player: `off_grid` says "you
/// aimed off the edge", `inert` says "you hit clean slime".
pub const ShapeOutcome = struct {
    /// Cells downgraded, indexed by the tier they were AT before the cast.
    downgraded: [c.Tier.size]u16 = [_]u16{0} ** c.Tier.size,
    /// Of those, how many were fully defused (green -> neutralized).
    neutralized: u16 = 0,
    /// Covered offsets that fell outside the grid.
    off_grid: u16 = 0,
    /// Covered cells with nothing to neutralize.
    inert: u16 = 0,

    /// Total cells the cast changed.
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
    const field = SlimeField.init(.{ .rows = 2, .cols = 3 }, res, rng.random());

    // 6 cells filled, 50 - 6 = 44 left in the reservoir.
    try testing.expectEqual(@as(u16, 6), field.grid.occupied());
    try testing.expectEqual(@as(u32, 44), field.reservoir.total());
    try testing.expectEqual(@as(u32, 50), field.remaining());
    try testing.expect(!field.is_exhausted());
}

test "init leaves cells empty when the reservoir cannot fill the grid" {
    var rng = prng(2);
    const field = SlimeField.init(.{ .rows = 4, .cols = 4 }, .{ .neutral = 5 }, rng.random());
    try testing.expectEqual(@as(u16, 5), field.grid.occupied());
    try testing.expect(field.reservoir.is_empty());
    // Filled top-first: the first 5 flat cells hold the slime.
    for (field.grid.live(), 0..) |cell, i| {
        try testing.expectEqual(i < 5, cell.is_slime());
    }
}

test "fill refills empty cells from the top row downward" {
    var rng = prng(3);
    var field = SlimeField.init(.{ .rows = 3, .cols = 2 }, .{ .neutral = 6 }, rng.random());
    try testing.expect(field.reservoir.is_empty());

    field.grid.set(0, 0, .empty);
    field.grid.set(0, 1, .empty);
    field.grid.set(2, 1, .empty);
    field.reservoir.neutral = 2;

    const filled = field.fill(rng.random());
    // Only 2 units available, and they go to the two TOPMOST empty cells.
    try testing.expectEqual(@as(u16, 2), filled);
    try testing.expect(field.grid.at(0, 0).is_slime());
    try testing.expect(field.grid.at(0, 1).is_slime());
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(2, 1));
}

test "fill draws every reservoir bucket and exhausts it exactly" {
    var rng = prng(4);
    var res = c.SlimeReservoir{ .neutral = 4 };
    res.tiered[ti(.red)] = 4;
    res.tiered[ti(.green)] = 4;
    const field = SlimeField.init(.{ .rows = 3, .cols = 4 }, res, rng.random());

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

test "reservoir slime always arrives at full difficulty" {
    // Casting cannot reach off-grid slime, so a refill after a cast brings in
    // an un-neutralized unit even though the grid was just cleaned.
    var rng = prng(16);
    var field = empty_field(1, 2);
    field.grid.put(0, .{ .tiered = .green });
    field.reservoir.tiered[ti(.red)] = 1;

    _ = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.get(0));

    _ = field.fill(rng.random());
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

test "eat_all eats the edible cells it can reach from the left edge" {
    var field = empty_field(1, 3);
    field.grid.put(0, .neutral);
    field.grid.put(1, .neutralized);
    field.grid.put(2, .neutral);

    const feast = field.eat_all(test_bal);

    // Nothing blocks, so the flood walks the whole row.
    try testing.expectEqual(@as(u16, 3), feast.cells);
    try testing.expectEqual(@as(u16, 2), feast.neutral);
    try testing.expectEqual(@as(u16, 1), feast.defused);
    try testing.expectEqual(3 * test_bal.hunger_cost_normal, feast.hunger);
    try testing.expectEqual(@as(u32, 3), feast.score);
    try testing.expectEqual(@as(u16, 0), feast.sheltered);
    try testing.expectEqual(@as(u16, 0), feast.walls);
    try testing.expect(field.is_exhausted());
}

test "a live hazard is never eaten and shelters everything behind it" {
    // The central mechanic: the wall survives, and so does the food it guards.
    var field = empty_field(1, 4);
    field.grid.put(0, .neutral);
    field.grid.put(1, .{ .tiered = .red });
    field.grid.put(2, .neutral);
    field.grid.put(3, .neutral);

    const feast = field.eat_all(test_bal);

    try testing.expectEqual(@as(u16, 1), feast.cells);
    try testing.expectEqual(@as(u16, 2), feast.sheltered);
    try testing.expectEqual(@as(u16, 1), feast.walls);
    try testing.expectEqual(test_bal.hunger_cost_normal, feast.hunger);
    // The hazard and both sheltered units are untouched; only cell 0 opened.
    try testing.expectEqual(c.SlimeCell.empty, field.grid.get(0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.get(1));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.get(2));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.get(3));
}

test "a neutralizer is consumed for FREE: no score, no hunger, and it conducts" {
    var field = empty_field(1, 3);
    field.grid.put(0, .neutral);
    field.grid.put(1, .{ .special = .neutralizer });
    field.grid.put(2, .neutral);

    const feast = field.eat_all(test_bal);
    // Everything goes — the neutralizer conducts and is swallowed en route —
    // but only the two neutrals are FOOD.
    try testing.expectEqual(@as(u16, 3), feast.cells);
    try testing.expectEqual(@as(u32, 2), feast.score);
    try testing.expectEqual(2 * test_bal.hunger_cost_normal, feast.hunger);
    try testing.expectEqual(@as(u16, 1), feast.agents);
    try testing.expectEqual(@as(u16, 0), feast.sheltered);
    try testing.expectEqual(@as(u16, 0), feast.walls);
    try testing.expectEqual(c.SlimeCell.empty, field.grid.get(1));
    try testing.expect(field.is_exhausted());
}

test "an eaten neutralizer fires a 3x3 Agent block, downgrading like a cast" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .red });
    // The door cell is the neutralizer: the flood swallows it immediately and
    // the 3x3 at (1,0) covers rows 0-2, cols 0-1 — six reds step to yellow.
    field.grid.set(1, 0, .{ .special = .neutralizer });

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 1), feast.agents);
    try testing.expectEqual(@as(u16, 1), feast.cells);
    try testing.expectEqual(@as(u32, 0), feast.score);
    try testing.expectEqual(@as(u32, 0), feast.hunger);
    try testing.expectEqual(@as(u16, 5), feast.agent_downgraded[ti(.red)]);
    try testing.expectEqual(@as(u16, 0), feast.agent_defused);
    // Yellow is still a wall: a red only steps one tier, so nothing opened.
    try testing.expectEqual(@as(u16, 5), field.grid.tier_count(.yellow));
    try testing.expectEqual(@as(u16, 3), field.grid.tier_count(.red));
}

test "the Agent block opens a green wall MID-FEAST and the meal flows through" {
    // The inline cascade in miniature: door neutralizer, green wall, food.
    var field = empty_field(1, 4);
    field.grid.put(0, .{ .special = .neutralizer });
    field.grid.put(1, .{ .tiered = .green });
    field.grid.put(2, .neutral);
    field.grid.put(3, .neutral);

    const feast = field.eat_all(test_bal);
    // The block defused the green as the neutralizer was swallowed; the SAME
    // flood ate the defused wall and everything it had sheltered.
    try testing.expectEqual(@as(u16, 4), feast.cells);
    try testing.expectEqual(@as(u16, 1), feast.agents);
    try testing.expectEqual(@as(u16, 1), feast.agent_defused);
    try testing.expectEqual(@as(u16, 1), feast.defused);
    try testing.expectEqual(@as(u32, 3), feast.score);
    try testing.expectEqual(@as(u16, 0), feast.sheltered);
    try testing.expectEqual(@as(u16, 0), feast.walls);
    try testing.expect(field.is_exhausted());
}

test "a chain of neutralizers eats through wall after wall in ONE feast" {
    var field = empty_field(1, 5);
    field.grid.put(0, .{ .special = .neutralizer });
    field.grid.put(1, .{ .tiered = .green });
    field.grid.put(2, .{ .special = .neutralizer });
    field.grid.put(3, .{ .tiered = .green });
    field.grid.put(4, .neutral);

    const feast = field.eat_all(test_bal);
    // Each swallowed neutralizer opened the next wall: the whole row falls.
    try testing.expectEqual(@as(u16, 5), feast.cells);
    try testing.expectEqual(@as(u16, 2), feast.agents);
    try testing.expectEqual(@as(u16, 2), feast.agent_defused);
    try testing.expectEqual(@as(u32, 3), feast.score);
    try testing.expect(field.is_exhausted());
}

test "a neutralizer settles the board FIRST, then its block fires on the settled cells" {
    // Collapse-then-effect, in a column: the red rides two rows above the
    // swallowed neutralizer, OUTSIDE its 3x3 — until the settle drops it to
    // the floor, inside.  Effect-then-collapse would leave it red.
    //   col0
    //   r0:  R
    //   r1:  .
    //   r2:  N   <- neutralizer, on the left edge
    //   r3:  .
    var field = empty_field(4, 1);
    field.grid.set(0, 0, .{ .tiered = .red });
    field.grid.set(2, 0, .{ .special = .neutralizer });

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 1), feast.agents);
    try testing.expectEqual(@as(u16, 1), feast.agent_downgraded[ti(.red)]);
    // The red fell to (3,0) before the 3x3 fired at rows 1-3, so it was hit.
    try testing.expectEqual(c.SlimeCell{ .tiered = .yellow }, field.grid.at(3, 0));
    try testing.expectEqual(@as(u16, 1), feast.cells);
    try testing.expectEqual(@as(u16, 1), feast.walls);
}

test "an egg never settles the board: the route past it is eaten whole" {
    // Only the NEUTRALIZER's board-changing effect settles mid-meal.  If the
    // egg triggered a collapse, the red at (0,1) would drop into (1,1) and
    // plug the floor route before (1,2) was reached.
    //   col: 0 1 2
    //   r0:  n R .
    //   r1:  n E n
    var field = empty_field(2, 3);
    field.grid.set(0, 0, .neutral);
    field.grid.set(0, 1, .{ .tiered = .red });
    field.grid.set(1, 0, .neutral);
    field.grid.set(1, 1, .{ .special = .egg });
    field.grid.set(1, 2, .neutral);

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 4), feast.cells);
    try testing.expectEqual(@as(u16, 1), feast.hatched);
    try testing.expectEqual(field.grid.index(1, 1), feast.hatched_cells[0]);
    try testing.expectEqual(@as(u16, 0), feast.sheltered);
    try testing.expectEqual(@as(u16, 1), feast.walls);
    // The red only fell once the meal ran dry.
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(1, 1));
}

test "a consumable special is food: eaten, scored, and hatched" {
    var field = empty_field(1, 3);
    field.grid.put(0, .neutral);
    field.grid.put(1, .{ .special = .egg });
    field.grid.put(2, .neutral);

    const feast = field.eat_all(test_bal);
    // The egg conducts AND feeds: nothing shelters behind it.
    try testing.expectEqual(@as(u16, 3), feast.cells);
    try testing.expectEqual(@as(u16, 0), feast.sheltered);
    try testing.expectEqual(@as(u16, 0), feast.walls);
    // Normal price, normal score — the hatch is the bonus.
    try testing.expectEqual(3 * test_bal.hunger_cost_normal, feast.hunger);
    try testing.expectEqual(@as(u32, 3), feast.score);
    try testing.expectEqual(@as(u16, 1), feast.hatched);
    try testing.expectEqual(@as(u16, 1), feast.hatched_cells[0]);
    try testing.expectEqual(c.SlimeCell.empty, field.grid.get(1));
    try testing.expect(field.is_exhausted());
}

test "no cast can ever change a special of any kind" {
    for ([_]c.SpecialKind{ .neutralizer, .egg }) |kind| {
        var field = empty_field(1, 1);
        field.grid.put(0, .{ .special = kind });
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const out = field.apply_shape(DOT, 0, 0);
            try testing.expectEqual(@as(u16, 0), out.total_downgraded());
            try testing.expectEqual(@as(u16, 1), out.inert);
        }
        try testing.expectEqual(c.SlimeCell{ .special = kind }, field.grid.get(0));
    }
}

test "the feast flows around a wall that does not span the grid" {
    // A wall only shelters what it actually covers: the flood goes around it
    // and eats the whole route; only THEN does the dry-pass settle drop the
    // wall into the hole beneath it.
    //   col: 0 1 2
    //   r0:  n # n
    //   r1:  n . n
    var field = empty_field(2, 3);
    field.grid.set(0, 0, .neutral);
    field.grid.set(0, 1, .{ .tiered = .green });
    field.grid.set(0, 2, .neutral);
    field.grid.set(1, 0, .neutral);
    field.grid.set(1, 1, .empty);
    field.grid.set(1, 2, .neutral);

    const feast = field.eat_all(test_bal);
    // All four neutrals fall to the feast; the settle after the pass drops
    // the green into (1,1), where it ends the meal still standing.
    try testing.expectEqual(@as(u16, 4), feast.cells);
    try testing.expectEqual(@as(u16, 0), feast.sheltered);
    try testing.expectEqual(@as(u16, 1), feast.walls);
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.at(1, 1));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 1));
}

test "gravity never plugs an open route: the pass is eaten whole, THEN falls feed the next" {
    // REGRESSION: the eager per-bite collapse used to drop the red riding
    // column 1 into the feast's route mid-meal, sheltering food that was
    // reachable when the pass began.  Now every pass eats its whole
    // contiguous path before gravity runs — and the dry-pass settle still
    // OPENS new food for the pass after it.
    //   col: 0 1
    //   r0:  R n
    //   r1:  R n
    //   r2:  R R
    //   r3:  n n
    var field = empty_field(4, 2);
    field.grid.set(0, 0, .{ .tiered = .red });
    field.grid.set(1, 0, .{ .tiered = .red });
    field.grid.set(2, 0, .{ .tiered = .red });
    field.grid.set(3, 0, .neutral);
    field.grid.set(0, 1, .neutral);
    field.grid.set(1, 1, .neutral);
    field.grid.set(2, 1, .{ .tiered = .red });
    field.grid.set(3, 1, .neutral);

    const feast = field.eat_all(test_bal);
    // Pass 1: the door neutral at (3,0), then along the floor to (3,1) —
    // the board holds still, so the red at (2,1) never falls into the way.
    // The settle then stacks column 0's reds on the floor and drops column
    // 1's food onto its red, opening the overhead route: pass 2 eats the two
    // neutrals now at (1,1) and (2,1) over the top.  Nothing is sheltered.
    try testing.expectEqual(@as(u16, 4), feast.cells);
    try testing.expectEqual(@as(u16, 0), feast.sheltered);
    try testing.expectEqual(@as(u16, 4), feast.walls);
    // The walls end settled: reds fill column 0's bottom three rows, and
    // column 1's red sits alone on the floor.
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(2, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(3, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(3, 1));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(2, 1));
}

test "a full-height wall in column 0 stops the feast at the door" {
    var field = empty_field(3, 2);
    var row: u8 = 0;
    while (row < 3) : (row += 1) {
        field.grid.set(row, 0, .{ .tiered = .red });
        field.grid.set(row, 1, .neutral);
    }

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 0), feast.cells);
    try testing.expectEqual(@as(u16, 3), feast.sheltered);
    try testing.expectEqual(@as(u16, 3), feast.walls);
    try testing.expectEqual(@as(u32, 0), feast.hunger_total());
}

test "defusing a wall opens the path on the following feast" {
    // The turn loop in miniature: this turn the wall holds, the team spends a
    // cast on it, next turn the food behind it is reachable.
    var field = empty_field(1, 3);
    field.grid.put(0, .{ .tiered = .green });
    field.grid.put(1, .neutral);
    field.grid.put(2, .neutral);

    const blocked = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 0), blocked.cells);
    try testing.expectEqual(@as(u16, 2), blocked.sheltered);

    // One cast takes green to defused — which also makes the wall itself food.
    _ = field.apply_shape(DOT, 0, 0);
    const opened = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 3), opened.cells);
    try testing.expectEqual(@as(u16, 1), opened.defused);
    try testing.expectEqual(@as(u16, 2), opened.neutral);
    try testing.expectEqual(@as(u16, 0), opened.sheltered);
}

test "empty cells conduct the feast without feeding it" {
    var field = empty_field(1, 3);
    field.grid.put(0, .empty);
    field.grid.put(1, .empty);
    field.grid.put(2, .neutral);

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 1), feast.cells);
    try testing.expectEqual(test_bal.hunger_cost_normal, feast.hunger);
}

test "eat_all on an empty field is a free no-op" {
    var field = empty_field(2, 2);
    field.grid.put(3, .neutral);

    // (1,1) is reachable across the empty corridor.
    const some = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 1), some.cells);

    const none = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 0), none.cells);
    try testing.expectEqual(@as(u32, 0), none.hunger_total());
    try testing.expectEqual(@as(u32, 0), none.score);
    try testing.expectEqual(@as(u16, 0), none.walls);
}

test "every eaten unit costs the same flat hunger" {
    // Difficulty decides how many casts a unit needs, not what it costs to eat:
    // by the time anything is eaten it is edible, so the price is uniform.
    for ([_]c.SlimeCell{ .neutral, .neutralized }) |cell| {
        var field = empty_field(1, 1);
        field.grid.put(0, cell);
        const feast = field.eat_all(test_bal);
        try testing.expectEqual(test_bal.hunger_cost_normal, feast.hunger_total());
        try testing.expectEqual(@as(u32, 1), feast.score);
    }
}

test "collapse drops survivors to the bottom, preserving column order" {
    var field = empty_field(4, 1);
    field.grid.put(0, .neutral);            // top
    field.grid.put(1, .empty);
    field.grid.put(2, .{ .tiered = .red });
    field.grid.put(3, .empty);             // bottom

    const moved = field.collapse();
    try testing.expectEqual(@as(u16, 2), moved);
    // Order top-to-bottom is preserved: neutral was above the red, still is.
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 0));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(2, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(3, 0));
}

test "collapse is per-column: slime never slides sideways" {
    var field = empty_field(2, 2);
    field.grid.set(0, 0, .neutral);
    field.grid.set(1, 0, .empty);
    field.grid.set(0, 1, .empty);
    field.grid.set(1, 1, .empty);

    _ = field.collapse();
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(1, 1));
}

test "collapse on a packed column moves nothing and is idempotent" {
    var field = empty_field(3, 2);
    paint(&field, .neutral);
    try testing.expectEqual(@as(u16, 0), field.collapse());

    var field2 = empty_field(3, 1);
    field2.grid.put(0, .neutral);
    _ = field2.collapse();
    const snapshot = field2.grid;
    try testing.expectEqual(@as(u16, 0), field2.collapse());
    try testing.expectEqualSlices(c.SlimeCell, snapshot.live(), field2.grid.live());
}

test "collapse conserves every unit" {
    var rng = prng(21);
    var res = c.SlimeReservoir{ .neutral = 6, .special = .{ 1, 1 } };
    res.tiered[ti(.red)] = 4;
    var field = SlimeField.init(.{ .rows = 4, .cols = 3 }, res, rng.random());
    _ = field.eat_all(test_bal);
    const before = field.grid.occupied();
    _ = field.collapse();
    try testing.expectEqual(before, field.grid.occupied());
}

test "turn settlement is eat (with settles between passes), then refill" {
    // Gravity runs BETWEEN passes: the dry-pass settle re-sorts the field,
    // so slime that was sealed when the feast started can be exposed and
    // eaten in the same turn.  The field comes back settled, and `fill` tops
    // it up from the rows the falls cleared.
    //
    //   . = empty   n = neutral   R = live red
    //        col0 col1
    //   row0   R    n     <- sealed NOW — but the settle after pass 1 exposes it
    //   row1   R    R
    //   row2   n    .     <- on the left edge, so this one is dinner
    var field = empty_field(3, 2);
    field.grid.put(field.grid.index(0, 0), .{ .tiered = .red });
    field.grid.put(field.grid.index(0, 1), .neutral);
    field.grid.put(field.grid.index(1, 0), .{ .tiered = .red });
    field.grid.put(field.grid.index(1, 1), .{ .tiered = .red });
    field.grid.put(field.grid.index(2, 0), .neutral);
    field.reservoir.neutral = 1;

    const feast = field.eat_all(test_bal);
    // Pass 1 takes (2,0) and runs dry; the settle drops every column — the
    // sealed neutral lands at (1,1), above the red that fell to (2,1), and
    // the door column's reds stack at (1,0)/(2,0).  Pass 2 then reaches the
    // neutral over the top of the walls: the seal did not survive the fall.
    try testing.expectEqual(@as(u16, 2), feast.cells);
    try testing.expectEqual(@as(u16, 0), feast.sheltered);
    try testing.expectEqual(@as(u16, 3), feast.walls);

    // The feast already settled the board: nothing left to fall.
    try testing.expectEqual(@as(u16, 0), field.collapse());
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(2, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(2, 1));

    // The one refill lands in the rows the falls cleared.
    var rng = prng(5);
    try testing.expectEqual(@as(u16, 1), field.fill(rng.random()));
    const top_filled = @intFromBool(field.grid.at(0, 0) != .empty) +
        @intFromBool(field.grid.at(0, 1) != .empty);
    try testing.expectEqual(@as(u8, 1), top_filled);
}

test "neutralizers are playable slime: the win requires eating them too" {
    var field = empty_field(1, 2);
    field.grid.put(0, .neutral);
    field.grid.put(1, .{ .special = .neutralizer });
    try testing.expect(!field.is_exhausted());

    // Both are consumed by one feast — the neutralizer for free — and only
    // then is the field spent.
    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 2), feast.cells);
    try testing.expectEqual(@as(u32, 1), feast.score);
    try testing.expectEqual(@as(u16, 0), field.grid.occupied());
    try testing.expect(field.is_exhausted());
}

test "an uneaten egg keeps the field unwon: eggs are playable slime" {
    var field = empty_field(1, 2);
    field.grid.put(0, .{ .tiered = .red });
    field.grid.put(1, .{ .special = .egg });

    // The red walls the egg in, so the feast gets nothing — and an egg still
    // on the grid is food the team has not eaten, so no win.  Both the red
    // and the egg count as playable: each can still be cleared.
    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 0), feast.cells);
    try testing.expectEqual(@as(u32, 2), field.remaining_playable());
    try testing.expect(!field.is_exhausted());
}

test "a field walled off with charges gone is not won" {
    // The dead position the session must detect: slime remains, unreachable.
    var field = empty_field(1, 2);
    field.grid.put(0, .{ .tiered = .red });
    field.grid.put(1, .neutral);

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 0), feast.cells);
    try testing.expect(!field.is_exhausted());
    try testing.expectEqual(@as(u32, 2), field.remaining_playable());
}

test "turn after turn, gravity and refills eventually feed every unit" {
    // Liveness: with casts available the whole reservoir does get consumed, so
    // the pathed feast is not a way to stall forever.
    var rng = prng(14);
    var res = c.SlimeReservoir{ .neutral = 7 };
    res.tiered[ti(.red)] = 6;
    res.tiered[ti(.green)] = 4;
    const total_units = res.total();
    var field = SlimeField.init(.{ .rows = 3, .cols = 3 }, res, rng.random());

    var eaten: u32 = 0;
    var hunger: u32 = 0;
    var score: u32 = 0;
    var turns: u32 = 0;
    while (!field.is_exhausted() and turns < 200) : (turns += 1) {
        // A generous team: defuse the whole grid every turn, then feast.
        var pass: u8 = 0;
        while (pass < 3) : (pass += 1) {
            var r: u8 = 0;
            while (r < field.grid.rows) : (r += 1) {
                var cl: u8 = 0;
                while (cl < field.grid.cols) : (cl += 1) _ = field.apply_shape(DOT, r, cl);
            }
        }
        const feast = field.eat_all(test_bal);
        eaten += feast.cells;
        hunger += feast.hunger_total();
        score += feast.score;
        _ = field.collapse();
        _ = field.fill(rng.random());
    }

    try testing.expect(field.is_exhausted());
    try testing.expectEqual(total_units, eaten);
    try testing.expectEqual(total_units * test_bal.hunger_cost_normal, hunger);
    // Every unit was defused before it was eaten, so every unit scored.
    try testing.expectEqual(total_units, score);
}

test "leaving hazards up costs the team the food, not extra hunger" {
    var rng = prng(9);
    var res = c.SlimeReservoir{ .neutral = 4 };
    res.tiered[ti(.red)] = 5;
    var field = SlimeField.init(.{ .rows = 3, .cols = 3 }, res, rng.random());

    const feast = field.eat_all(test_bal);
    // Whatever it managed to eat, it paid the flat rate and nothing more.
    try testing.expectEqual(feast.cells * test_bal.hunger_cost_normal, feast.hunger_total());
    try testing.expectEqual(@as(u32, feast.cells), feast.score);
    // And the reds are all still standing.
    try testing.expectEqual(@as(u16, 5), field.grid.hazard_count());
}

test "defusing before the feast turns a wall into food" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .green });

    // One cast over the whole 3x3 defuses all nine, so all nine are edible and
    // nothing blocks the flood.
    _ = field.apply_shape(SQUARE_3X3, 1, 1);

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 9), feast.cells);
    try testing.expectEqual(@as(u32, 9), feast.score);
    try testing.expectEqual(@as(u16, 0), feast.walls);
    try testing.expectEqual(9 * test_bal.hunger_cost_normal, feast.hunger_total());
}

test "field ops are reproducible for a given seed" {
    const run = struct {
        fn go(seed: u64) SlimeField {
            var rng = prng(seed);
            var res = c.SlimeReservoir{ .neutral = 10 };
            res.tiered[ti(.red)] = 10;
            var field = SlimeField.init(.{ .rows = 3, .cols = 4 }, res, rng.random());
            _ = field.apply_shape(PLUS, 1, 1);
            _ = field.eat_all(test_bal);
            _ = field.collapse();
            _ = field.fill(rng.random());
            return field;
        }
    }.go;

    const a = run(42);
    const b = run(42);
    try testing.expectEqualSlices(c.SlimeCell, a.grid.live(), b.grid.live());
    try testing.expectEqual(a.reservoir, b.reservoir);
}

test "eggs draw from the reservoir like any other unit" {
    var rng = prng(23);
    var res = c.SlimeReservoir{ .neutral = 2 };
    res.special[@intFromEnum(c.SpecialKind.egg)] = 2;
    res.special[@intFromEnum(c.SpecialKind.neutralizer)] = 2;
    const field = SlimeField.init(.{ .rows = 2, .cols = 3 }, res, rng.random());

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

