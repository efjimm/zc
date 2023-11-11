// TODO:
// Instead of ArrayLists use *BoundedArray
//   Makes OOM easier to handle via less allocations
//   Can write `ensureUnusedCapacity(n)` by pre-allocating root.level + n BoundedArrays
// Use MultiArrayLists for faster iteration of Node.range/KV.key
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Position = @import("Position.zig").Position;
const Range = Position.Range;
const PosInt = Position.Int;
const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;

pub fn RTree(comptime V: type, comptime min_children: usize) type {
    return struct {
        const max_children: comptime_int = min_children * 2;
        const ListPool = @import("pool.zig").MemoryPool(std.BoundedArray(Node, max_children), .{});

        root: Node = .{
            .level = 0,
            .range = .{
                .tl = .{ .x = 0, .y = 0 },
                .br = .{ .x = 0, .y = 0 },
            },
            .data = .{ .values = .{} },
        },
        pool: ListPool = .{},

        const Self = @This();

        const KV = struct {
            key: Range,
            /// List of cells that depend on the cells in `key`
            value: V,
        };

        pub const SearchItem = struct {
            key_ptr: *Range,
            value_ptr: *V,
        };

        const Node = struct {
            const ValueList = std.MultiArrayList(KV);

            const Data = union {
                children: *std.BoundedArray(Node, max_children),
                values: ValueList,
            };

            level: usize,
            range: Range,
            data: Data,

            /// Frees all memory associated with `node` and its children, and calls
            /// `context.deinitValue` on every instance of `V` in the tree.
            fn deinitContext(node: *Node, allocator: Allocator, context: anytype) void {
                if (node.isLeaf()) {
                    if (@TypeOf(context) != void) {
                        for (node.data.values.items(.value)) |*v| {
                            context.deinit(allocator, v);
                        }
                    }
                    node.data.values.deinit(allocator);
                } else {
                    for (node.data.children.slice()) |*n| n.deinitContext(allocator, context);
                }
                node.* = undefined;
            }

            fn isLeaf(node: *const Node) bool {
                return node.level == 0;
            }

            fn search(
                node: *const Node,
                range: Range,
                list: *std.ArrayList(SearchItem),
            ) Allocator.Error!void {
                if (node.isLeaf()) {
                    for (node.data.values.items(.key), 0..) |*k, i| {
                        if (range.intersects(k.*)) {
                            try list.append(.{
                                .key_ptr = k,
                                .value_ptr = &node.data.values.items(.value)[i],
                            });
                        }
                    }
                } else {
                    for (node.data.children.constSlice()) |*n| {
                        if (range.intersects(n.range)) {
                            try n.search(range, list);
                        }
                    }
                }
            }

            fn getSingleRecursive(node: *Node, key: Range) ?struct { *Range, *V } {
                if (node.isLeaf()) {
                    return for (node.data.values.items(.key), 0..) |*k, i| {
                        if (k.eql(key))
                            break .{ k, &node.data.values.items(.value)[i] };
                    } else null;
                }

                return for (node.data.children.slice()) |*n| {
                    if (n.range.contains(key)) {
                        if (n.getSingleRecursive(key)) |res| break res;
                    }
                } else null;
            }

            fn getSingle(node: *Node, key: Range) ?struct { *Range, *V } {
                return if (node.range.contains(key)) getSingleRecursive(node, key) else null;
            }

            fn bestLeaf(node: *Node, key: Range) *Node {
                assert(node.level == 1);
                const slice = node.data.children.constSlice();
                assert(slice.len > 0);

                // Minimize overlap
                var min_index: usize = 0;
                var min_enlargement: u64 = 0;
                var min_overlap: u64 = std.math.maxInt(u64);

                for (slice, 0..) |n1, i| {
                    const r = n1.range.merge(key);
                    const enlargement = r.area() - n1.range.area();

                    const total_overlap = totalOverlap(slice, r);

                    if (total_overlap <= min_overlap) {
                        if (total_overlap != min_overlap or min_enlargement < enlargement) {
                            min_index = i;
                            min_enlargement = enlargement;
                            min_overlap = total_overlap;
                        }
                    }
                }
                return &node.data.children.slice()[min_index];
            }

            fn totalOverlap(nodes: []const Node, range: Range) u64 {
                var total: u64 = 0;
                for (nodes) |n| {
                    total += range.overlapArea(n.range);
                }
                return total;
            }

            /// Find best child to insert into.
            /// Gets the child with the smallest area increase to store `key`
            fn bestChild(node: *Node, key: Range) *Node {
                assert(!node.isLeaf());

                if (node.level == 1) return bestLeaf(node, key);

                // Minimize area enlargement

                const slice = node.data.children.constSlice();
                assert(slice.len > 0);

                var min_index: usize = 0;
                var min_diff, var min_area = blk: {
                    const rect = Range.merge(slice[0].range, key);
                    break :blk .{ rect.area() - slice[0].range.area(), slice[0].range.area() };
                };

                for (slice[1..], 1..) |n, i| {
                    const rect = Range.merge(n.range, key);
                    const a = n.range.area();
                    const diff = rect.area() - a;
                    if (diff <= min_diff) {
                        if (diff != min_diff or a < min_area) {
                            min_index = i;
                            min_area = a;
                            min_diff = diff;
                        }
                    }
                }

                return &node.data.children.slice()[min_index];
            }

            fn recalcBoundingRange(node: Node) Range {
                if (node.isLeaf()) {
                    const slice: []const Range = node.data.values.items(.key);
                    assert(slice.len > 0);

                    var range = slice[0];
                    for (slice[1..]) |k| range = range.merge(k);
                    return range;
                }

                const slice = node.data.children.constSlice();
                assert(slice.len > 0);
                var range = slice[0].range;
                for (slice[1..]) |n| {
                    range = range.merge(n.range);
                }
                return range;
            }

            /// Removes `key` and its associated value from the tree.
            fn remove(
                node: *Node,
                key: Range,
            ) struct {
                /// Removed kv pair (if any)
                ?KV,
                /// Whether `node` needs to be merged with another one
                bool,
                /// Whether the node's range needs to be recalculated
                bool,

                /// Index of node needing to be merged in parent
                ?usize,
                /// Parent of node needing to be merged
                ?*Node,
            } {
                if (node.isLeaf()) {
                    const list = &node.data.values;
                    const ret = for (list.items(.key), 0..) |k, i| {
                        if (!k.eql(key)) continue;
                        _ = list.swapRemove(i);
                        break .{
                            KV{
                                .key = k,
                                .value = if (V == void) {} else list.items(.value)[i],
                            },
                            list.len < min_children,
                            key.tl.anyMatch(node.range.tl) or key.br.anyMatch(node.range.br),
                            null,
                            null,
                        };
                    } else .{ null, false, false, null, null };

                    if (list.len > 0 and ret[2])
                        node.range = node.recalcBoundingRange();
                    return ret;
                }

                const list = node.data.children;
                for (list.slice(), 0..) |*n, i| {
                    if (!n.range.contains(key)) continue;
                    const res = n.remove(key);
                    const kv, const merge_node, const recalc, var index, var parent = res;
                    if (kv == null) continue; // Didn't find a value

                    if (merge_node and list.len > 1) {
                        parent = node;
                        index = i;

                        if (recalc) {
                            const start = @intFromBool(i == 0);
                            var range = list.constSlice()[start].range;
                            for (list.constSlice()[0..i]) |c| range = range.merge(c.range);
                            for (list.constSlice()[i + 1 ..]) |c| range = range.merge(c.range);
                            node.range = range;
                        }
                    } else if (recalc) {
                        node.range = node.recalcBoundingRange();
                    }

                    const len = list.len - @intFromBool(parent == node);
                    return .{ kv, len < min_children, recalc, index, parent };
                } else return .{ null, false, false, null, null };
                unreachable;
            }

            fn getRange(a: anytype) Range {
                return switch (@TypeOf(a)) {
                    Node, *Node, *const Node => a.range,
                    KV, *KV, *const KV => a.key,
                    Range, *Range, *const Range => a,
                    else => @compileError("Invalid type " ++ @typeName(@TypeOf(a))),
                };
            }

            fn split(node: *Node, allocator: Allocator, pool: *ListPool) Allocator.Error!Node {
                if (node.isLeaf()) {
                    return node.splitLeaf(allocator);
                } else {
                    return node.splitBranch(allocator, pool);
                    // return node.splitNode(allocator, pool, .branch);
                }
            }

            fn DistributionGroup(comptime T: type) type {
                return struct {
                    entries: std.BoundedArray(T, max_children),
                    range: Range,
                };
            }
            fn Distribution(comptime T: type) type {
                return [2]DistributionGroup(T);
            }

            fn Distributions(comptime T: type) type {
                return std.BoundedArray(Distribution(T), dist_count);
            }

            const dist_count = 2 * (max_children - 2 * min_children + 2);

            fn chooseSplitAxis(node: *const Node, comptime T: type) Distributions(T) {
                var min_perimeter: u64 = std.math.maxInt(u64);
                var ret: Distributions(T) = .{};

                inline for (.{ .x, .y }) |d| {
                    var sorted_lower: std.BoundedArray(T, max_children) = .{};
                    var sorted_upper: std.BoundedArray(T, max_children) = .{};

                    // TODO: Elide copies (sort out of place)
                    if (T == Node) {
                        sorted_lower.appendSliceAssumeCapacity(node.data.children.constSlice());
                        sorted_upper.appendSliceAssumeCapacity(node.data.children.constSlice());
                    } else {
                        const s = node.data.values.slice();
                        for (s.items(.key), s.items(.value)) |k, v| {
                            sorted_lower.appendAssumeCapacity(.{ .key = k, .value = v });
                            sorted_upper.appendAssumeCapacity(.{ .key = k, .value = v });
                        }
                    }

                    const LowerContext = struct {
                        pub fn compare(_: @This(), lhs: T, rhs: T) bool {
                            return switch (d) {
                                .x => getRange(lhs).tl.x < getRange(rhs).tl.x,
                                .y => getRange(lhs).tl.y < getRange(rhs).tl.y,
                                else => unreachable,
                            };
                        }
                    };

                    const UpperContext = struct {
                        pub fn compare(_: @This(), lhs: T, rhs: T) bool {
                            return switch (d) {
                                .x => getRange(lhs).br.x < getRange(rhs).br.x,
                                .y => getRange(lhs).br.y < getRange(rhs).br.y,
                                else => unreachable,
                            };
                        }
                    };

                    std.sort.heap(T, sorted_lower.slice(), LowerContext{}, LowerContext.compare);
                    std.sort.heap(T, sorted_upper.slice(), UpperContext{}, UpperContext.compare);

                    var sum: u64 = 0;
                    var temp: Distributions(T) = .{};
                    temp.len = 0;
                    inline for (.{
                        sorted_lower.constSlice(),
                        sorted_upper.constSlice(),
                    }) |entries| {
                        for (0..max_children - 2 * min_children + 2) |k| {
                            var r1: Range = getRange(entries[0]);
                            var r2: Range = getRange(entries[min_children - 1 + k]);
                            for (entries[1 .. min_children - 1 + k]) |e| r1 = r1.merge(getRange(e));
                            for (entries[min_children + k ..]) |e| r2 = r2.merge(getRange(e));

                            temp.appendAssumeCapacity(.{
                                .{ .range = r1, .entries = .{} },
                                .{ .range = r2, .entries = .{} },
                            });
                            const g1 = &temp.slice()[temp.len - 1][0].entries;
                            const g2 = &temp.slice()[temp.len - 1][1].entries;
                            g1.appendSliceAssumeCapacity(entries[0 .. min_children - 1 + k]);
                            g2.appendSliceAssumeCapacity(entries[min_children - 1 + k ..]);
                            sum += r1.perimeter() + r2.perimeter();
                        }
                    }

                    if (sum <= min_perimeter) {
                        min_perimeter = sum;
                        ret = temp;
                    }
                }

                return ret;
            }

            pub fn chooseSplitIndex(comptime T: type, dists: *const Distributions(T)) usize {
                assert(dists.len > 0);

                var min_overlap: u64 = comptime std.math.maxInt(u64);
                var min_area: u64 = comptime std.math.maxInt(u64);
                var best_index: usize = 0;

                for (dists.constSlice(), 0..) |*dist, i| {
                    const first, const second = .{ &dist[0], &dist[1] };
                    const overlap = first.range.overlapArea(second.range);

                    if (overlap < min_overlap) {
                        min_overlap = overlap;
                        min_area = first.range.area() + second.range.area();
                        best_index = i;
                    } else if (overlap == min_overlap) {
                        const a = first.range.area() + second.range.area();
                        if (a < min_area) {
                            min_area = a;
                            best_index = i;
                        }
                    }
                }
                return best_index;
            }

            fn splitLeaf(
                node: *Node,
                allocator: Allocator,
            ) Allocator.Error!Node {
                const dists: Distributions(KV) = node.chooseSplitAxis(KV);
                const index = chooseSplitIndex(KV, &dists);
                const d = &dists.constSlice()[index];

                var new_entries: ValueList = .{};
                try new_entries.ensureUnusedCapacity(allocator, d[1].entries.len);
                for (d[1].entries.constSlice()) |e| {
                    new_entries.appendAssumeCapacity(e);
                }

                node.data.values.len = 0;
                for (d[0].entries.constSlice()) |e| {
                    node.data.values.appendAssumeCapacity(e);
                }
                node.range = d[0].range;
                return .{
                    .level = node.level,
                    .range = d[1].range,
                    .data = .{ .values = new_entries },
                };
            }

            fn splitBranch(
                node: *Node,
                allocator: Allocator,
                pool: *ListPool,
            ) Allocator.Error!Node {
                assert(!node.isLeaf());

                const dists: Distributions(Node) = node.chooseSplitAxis(Node);
                const index = chooseSplitIndex(Node, &dists);
                const d = &dists.constSlice()[index];

                const new_entries = try pool.create(allocator);
                new_entries.* = d[1].entries;

                node.data.children.* = d[0].entries;
                node.range = d[0].range;
                return .{
                    .level = node.level,
                    .range = d[1].range,
                    .data = .{ .children = new_entries },
                };
            }

            /// Splits a node in place, returning the other half as a new node.
            fn splitNode(
                node: *Node,
                allocator: Allocator,
                pool: *ListPool,
                comptime node_type: enum { branch, leaf },
            ) !Node {
                const entries = switch (node_type) {
                    .leaf => &node.data.values,
                    .branch => node.data.children,
                };

                var new_entries = switch (node_type) {
                    .leaf => blk: {
                        var new_entries: ValueList = .{};
                        try new_entries.ensureTotalCapacity(allocator, max_children);
                        break :blk new_entries;
                    },
                    .branch => blk: {
                        const mem = try pool.create(allocator);
                        mem.* = .{};
                        break :blk mem;
                    },
                };
                errdefer switch (node_type) {
                    .leaf => new_entries.deinit(allocator),
                    .branch => allocator.destroy(new_entries),
                };

                const seed2, const seed1 = blk: {
                    switch (node_type) {
                        .leaf => {
                            const i_1, const i_2 = linearSplit(entries.items(.key));
                            assert(i_1 < i_2);
                            const res = .{ entries.get(i_2), entries.get(i_1) };
                            entries.orderedRemove(i_2);
                            entries.orderedRemove(i_1);
                            break :blk res;
                        },
                        .branch => {
                            const i_1, const i_2 = linearSplit(entries.constSlice());
                            assert(i_1 < i_2);
                            break :blk .{ entries.orderedRemove(i_2), entries.orderedRemove(i_1) };
                        },
                    }
                };

                var bound2 = getRange(seed2);
                new_entries.appendAssumeCapacity(seed2);

                for (0..min_children - 1) |_| {
                    const e = entries.pop();
                    bound2 = bound2.merge(getRange(e));
                    new_entries.appendAssumeCapacity(e);
                }

                entries.appendAssumeCapacity(seed1);
                node.range = node.recalcBoundingRange();

                return .{
                    .level = node.level,
                    .range = bound2,
                    .data = switch (node_type) {
                        .leaf => .{ .values = new_entries },
                        .branch => .{ .children = new_entries },
                    },
                };
            }

            const DimStats = struct {
                const maxInt = std.math.maxInt;
                const minInt = std.math.minInt;

                min_tl: PosInt = maxInt(PosInt),
                max_tl: PosInt = minInt(PosInt),

                max_br: PosInt = minInt(PosInt),
                min_br: PosInt = maxInt(PosInt),

                tl_index: usize = 0,
                br_index: usize = 0,

                fn farthest(s: DimStats) PosInt {
                    return if (s.max_br > s.min_tl)
                        s.max_br - s.min_tl
                    else
                        s.min_tl - s.max_br;
                }

                fn nearest(s: DimStats) PosInt {
                    return if (s.min_br > s.max_tl)
                        s.min_br - s.max_tl
                    else
                        s.max_tl - s.min_br;
                }

                fn computeDim(s: *DimStats, lo: PosInt, hi: PosInt, i: usize) void {
                    s.min_tl = @min(s.min_tl, lo);
                    s.max_br = @max(s.max_br, hi);

                    if (lo > s.max_tl) {
                        s.max_tl = lo;
                        s.tl_index = i;
                    }

                    if (hi < s.min_br) {
                        s.min_br = hi;
                        s.br_index = i;
                    }
                }
            };

            fn linearSplit(entries: anytype) struct { usize, usize } {
                var dx = DimStats{};
                var dy = DimStats{};

                if (entries.len > 2) {
                    for (entries, 0..) |e, i| {
                        const rect = getRange(e);
                        dx.computeDim(rect.tl.x, rect.br.x, i);
                        dy.computeDim(rect.tl.y, rect.br.y, i);
                    }
                }

                const max = std.math.maxInt(PosInt);
                const norm_x = std.math.divTrunc(PosInt, dx.nearest(), dx.farthest()) catch max;
                const norm_y = std.math.divTrunc(PosInt, dy.nearest(), dy.farthest()) catch max;
                const x, const y = if (norm_x > norm_y)
                    .{ dx.tl_index, dx.br_index }
                else
                    .{ dy.tl_index, dy.br_index };

                return if (x < y)
                    .{ x, y }
                else if (x > y)
                    .{ y, x }
                else if (x == 0)
                    .{ 0, 1 }
                else
                    .{ 0, y };
            }
        };

        /// Returns an unorded list of key-value pairs whose keys intersect `range`
        pub fn search(
            tree: Self,
            allocator: Allocator,
            range: Range,
        ) Allocator.Error![]SearchItem {
            var list = std.ArrayList(SearchItem).init(allocator);
            errdefer list.deinit();

            try tree.root.search(range, &list);
            return list.toOwnedSlice();
        }

        fn mergeRoots(
            tree: *Self,
            allocator: Allocator,
            new_node: Node,
        ) Allocator.Error!void {
            // Root node got split, need to create a new root
            var new_root = Node{
                .level = new_node.level + 1,
                .range = Range.merge(tree.root.range, new_node.range),
                .data = .{
                    .children = blk: {
                        const mem = try tree.pool.create(allocator);
                        mem.* = .{};
                        break :blk mem;
                    },
                },
            };

            new_root.data.children.appendSliceAssumeCapacity(&.{ tree.root, new_node });
            tree.root = new_root;
        }

        fn putNode(
            tree: *Self,
            allocator: Allocator,
            node: *Node,
            key: Range,
            value: V,
        ) !?Node {
            var ok = true;
            defer if (ok) {
                // Update the node's range if there are no errors
                node.range = node.range.merge(key);
            };
            errdefer ok = false;

            if (node.isLeaf()) {
                node.data.values.ensureUnusedCapacity(allocator, 1) catch return error.NotAdded;
                node.data.values.appendAssumeCapacity(.{ .key = key, .value = value });
                errdefer _ = node.data.values.pop();

                if (node.data.values.len >= max_children) {
                    // Don't merge ranges in this branch, split does that
                    ok = false;
                    // Too many kvs, need to split this node
                    const new_node = node.split(allocator, &tree.pool) catch return error.NotAdded;
                    return new_node;
                }
                return null;
            }

            // Branch node
            const list = node.data.children;

            const best = node.bestChild(key);
            const maybe_new_node = try tree.putNode(allocator, best, key, value);

            if (maybe_new_node) |split_node| {
                // Child node was split, need to add new node to child list
                list.appendAssumeCapacity(split_node);

                if (list.len >= max_children) {
                    ok = false;
                    const new_node = try node.split(allocator, &tree.pool);
                    return new_node;
                }
            }

            return null;
        }

        /// Finds the key/value pair whose key matches `key` and returns pointers
        /// to the key and value, or `null` if not found.
        pub fn get(tree: *Self, key: Range) ?struct { *Range, *V } {
            return tree.root.getSingle(key);
        }

        pub fn put(
            tree: *Self,
            allocator: Allocator,
            key: Range,
            value: V,
        ) Allocator.Error!void {
            return tree.putContext(allocator, key, value, {});
        }

        pub fn putContext(
            tree: *Self,
            allocator: Allocator,
            key: Range,
            value: V,
            context: anytype,
        ) Allocator.Error!void {
            var maybe_new_node = tree.putNode(allocator, &tree.root, key, value) catch
                return error.OutOfMemory;
            if (maybe_new_node) |*new_node| {
                errdefer new_node.deinitContext(allocator, context);
                try tree.mergeRoots(allocator, new_node.*);
            }
        }

        /// Removes `key` and its associated value from the tree.
        pub fn remove(
            tree: *Self,
            allocator: Allocator,
            key: Range,
        ) Allocator.Error!void {
            return tree.removeContext(allocator, key, {});
        }

        /// Removes `key` and its associated value from the true.
        pub fn removeContext(
            tree: *Self,
            allocator: Allocator,
            key: Range,
            context: anytype,
        ) Allocator.Error!void {
            const res = tree.root.remove(key);

            if (@TypeOf(context) != void) {
                if (res[0]) |kv| {
                    var temp = kv;
                    context.deinit(&temp.value);
                }
            }
            const parent = res[4] orelse return;
            const index = res[3].?;
            var child: Node = parent.data.children.swapRemove(index);

            try tree.reAddRecursive(allocator, &child, context);
        }

        pub fn deinit(tree: *Self, allocator: Allocator) void {
            return tree.deinitContext(allocator, {});
        }

        pub fn deinitContext(
            tree: *Self,
            allocator: Allocator,
            context: anytype,
        ) void {
            tree.root.deinitContext(allocator, context);
            tree.pool.deinit(allocator);
            tree.* = undefined;
        }

        /// Adds all keys contained in the tree belonging to `root` into `tree`
        fn reAddRecursive(
            tree: *Self,
            allocator: Allocator,
            root: *Node,
            context: anytype,
        ) Allocator.Error!void {
            var maybe_err: Allocator.Error!void = {};
            if (root.isLeaf()) {
                defer root.data.values.deinit(allocator);
                while (root.data.values.popOrNull()) |temp| {
                    var kv = temp;
                    tree.put(allocator, kv.key, kv.value) catch |err| {
                        if (@TypeOf(context) != void)
                            context.deinit(allocator, &kv.value);
                        maybe_err = err;
                    };
                }
            } else {
                while (root.data.children.popOrNull()) |temp| {
                    var child = temp;
                    tree.reAddRecursive(allocator, &child, context) catch |err| {
                        maybe_err = err;
                    };
                }
            }
            return maybe_err;
        }
    };
}

pub fn DependentTree(comptime min_children: usize) type {
    return struct {
        rtree: Tree = .{},

        const Self = @This();
        const RangeList = std.ArrayListUnmanaged(Range);
        const Tree = RTree(RangeList, min_children);
        const Context = struct {
            capacity: usize = 1,

            fn init(self: Context, allocator: Allocator) !RangeList {
                return RangeList.initCapacity(allocator, self.capacity);
            }

            fn deinit(_: Context, allocator: Allocator, value: *RangeList) void {
                value.deinit(allocator);
            }
        };

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.rtree.deinitContext(allocator, Context{});
            self.* = undefined;
        }

        pub fn get(self: *Self, key: Range) ?struct { *Range, *RangeList } {
            return self.rtree.get(key);
        }

        pub fn put(
            self: *Self,
            allocator: Allocator,
            key: Range,
            value: Range,
        ) Allocator.Error!void {
            return self.putSlice(allocator, key, &.{value});
        }

        pub fn putSlice(
            self: *Self,
            allocator: Allocator,
            key: Range,
            values: []const Range,
        ) Allocator.Error!void {
            if (self.get(key)) |kv| {
                try kv[1].appendSlice(allocator, values);
                return;
            }

            var list = try RangeList.initCapacity(allocator, values.len);
            list.appendSliceAssumeCapacity(values);

            var maybe_new_node = self.rtree.putNode(
                allocator,
                &self.rtree.root,
                key,
                list,
            ) catch |err| switch (err) {
                error.NotAdded => {
                    list.deinit(allocator);
                    return error.OutOfMemory;
                },
                else => |e| return e,
            };
            if (maybe_new_node) |*new_node| {
                errdefer new_node.deinitContext(allocator, Context{});
                try self.rtree.mergeRoots(allocator, new_node.*);
            }
        }

        pub fn search(
            self: *Self,
            allocator: Allocator,
            key: Range,
        ) Allocator.Error![]Tree.SearchItem {
            return self.rtree.search(allocator, key);
        }

        pub fn removeKey(
            self: *Self,
            allocator: Allocator,
            key: Range,
        ) Allocator.Error!void {
            return self.rtree.removeContext(allocator, key, Context{});
        }

        /// Removes `value` from the list of values associated with `key`.
        /// Removes `key` if there are no values left after removal.
        pub fn removeValue(
            self: *Self,
            allocator: Allocator,
            key: Range,
            value: Range,
        ) Allocator.Error!void {
            const res = removeNode(&self.rtree.root, allocator, key, value);

            const parent: *Tree.Node = res[4] orelse return;
            const index: usize = res[3].?;
            assert(parent.data.children.len > 1);
            var child = parent.data.children.swapRemove(index);
            assert(child.level < self.rtree.root.level);

            try self.reAddRecursive(allocator, &child);
        }

        /// Adds all keys contained in the tree belonging to `root` into `tree`
        fn reAddRecursive(
            self: *Self,
            allocator: Allocator,
            root: *Tree.Node,
        ) Allocator.Error!void {
            return self.rtree.reAddRecursive(allocator, root, Context{});
        }

        /// Custom implementation of `remove` for the DependentTree
        /// Removes `value` from the entry with key `key`
        fn removeNode(
            node: *Tree.Node,
            allocator: Allocator,
            key: Range,
            value: Range,
        ) struct {
            /// Whether any item was removed
            bool,
            /// Whether `node` needs to be merged with another one
            bool,
            /// Whether the node's range needs to be recalculated
            bool,

            ?usize,
            ?*Tree.Node,
        } {
            if (node.isLeaf()) {
                const list = &node.data.values;
                return for (list.items(.key), 0..) |k, i| {
                    if (!k.eql(key)) continue;

                    const values = &list.items(.value)[i];
                    errdefer if (values.items.len == 0) {
                        var old_kv = list.swapRemove(i);
                        Context.deinit(.{}, allocator, &old_kv.value);
                    };

                    // Found matching key
                    // Now find the matching value
                    for (values.items, 0..) |v, j| {
                        if (!v.eql(value)) continue;
                        _ = values.swapRemove(j);
                        break;
                    }

                    if (values.items.len == 0) {
                        // This KV has no more values, so remove it entirely
                        var old_value = list.items(.value)[i];
                        list.swapRemove(i);
                        Context.deinit(.{}, allocator, &old_value);

                        const recalc = key.tl.anyMatch(node.range.tl) or
                            key.br.anyMatch(node.range.br);
                        if (list.len > 0 and recalc)
                            node.range = node.recalcBoundingRange();

                        break .{
                            true,
                            list.len < min_children,
                            recalc,
                            null,
                            null,
                        };
                    }

                    // Didn't remove a kv, don't return a new node and don't recalculate
                    // minimum bounding rectangles
                    break .{ true, false, false, null, null };
                } else .{ false, false, false, null, null };
            }

            const list = node.data.children;
            for (list.slice(), 0..) |*n, i| {
                if (!n.range.contains(key)) continue;

                const res = removeNode(n, allocator, key, value);
                const found, const merge_node, const recalc, var index, var parent = res;
                if (!found) continue;

                if (merge_node and list.len > 1) {
                    parent = node;
                    index = i;

                    if (recalc) {
                        const start = @intFromBool(i == 0);
                        var range = list.constSlice()[start].range;
                        for (list.constSlice()[0..i]) |c| range = range.merge(c.range);
                        for (list.constSlice()[i + 1 ..]) |c| range = range.merge(c.range);
                        node.range = range;
                    }
                } else if (recalc) {
                    node.range = node.recalcBoundingRange();
                }

                const len = list.len - @intFromBool(parent == node);
                return .{ true, len < min_children, recalc, index, parent };
            } else return .{ false, false, false, null, null };
            unreachable;
        }

        test "DependentTree1" {
            const t = std.testing;

            var tree = Self{};
            defer tree.deinit(t.allocator);

            try t.expectEqual(@as(usize, 0), tree.rtree.root.data.values.len);
            try t.expect(tree.rtree.root.isLeaf());

            const data = .{
                .{
                    // Key
                    Range.init(11, 2, 11, 2),
                    .{ // Values
                        Range.initSingle(0, 0),
                        Range.initSingle(10, 10),
                    },
                },
                .{
                    Range.init(0, 0, 2, 2),
                    .{
                        Range.initSingle(500, 500),
                        Range.initSingle(500, 501),
                        Range.initSingle(500, 502),
                    },
                },
                .{
                    Range.init(1, 1, 3, 3),
                    .{
                        Range.initSingle(501, 500),
                        Range.initSingle(501, 501),
                        Range.initSingle(501, 502),
                    },
                },
                .{
                    Range.init(1, 1, 10, 10),
                    .{
                        Range.initSingle(502, 500),
                        Range.initSingle(502, 501),
                        Range.initSingle(502, 502),
                        Range.initSingle(502, 503),
                        Range.initSingle(502, 504),
                        Range.initSingle(502, 505),
                    },
                },
                .{
                    Range.init(5, 5, 10, 10),
                    .{
                        Range.initSingle(503, 500),
                        Range.initSingle(503, 501),
                    },
                },
                .{
                    Range.init(3, 3, 4, 4),
                    .{
                        Range.initSingle(503, 500),
                        Range.initSingle(503, 501),
                    },
                },
                .{
                    Range.init(3, 3, 4, 4),
                    .{
                        Range.initSingle(503, 502),
                    },
                },
                .{
                    Range.init(3, 3, 4, 4),
                    .{
                        Range.initSingle(503, 502),
                    },
                },
                .{
                    Range.init(3, 3, 4, 4),
                    .{
                        Range.initSingle(503, 502),
                    },
                },
            };

            inline for (data) |d| {
                const key, const values = d;
                try tree.putSlice(t.allocator, key, &values);
            }

            try t.expectEqual(Range.init(0, 0, 11, 10), tree.rtree.root.range);

            {
                const res = try tree.search(t.allocator, Range.init(3, 3, 4, 4));
                defer t.allocator.free(res);

                const expected_results = .{
                    Range.initSingle(501, 500),
                    Range.initSingle(501, 501),
                    Range.initSingle(501, 502),
                    Range.initSingle(502, 500),
                    Range.initSingle(502, 501),
                    Range.initSingle(502, 502),
                    Range.initSingle(502, 503),
                    Range.initSingle(502, 504),
                    Range.initSingle(502, 505),
                    Range.initSingle(503, 500),
                    Range.initSingle(503, 501),
                    Range.initSingle(503, 502),
                };

                // Check that all ranges in `expected_results` are found in `res` in ANY order.
                for (res) |kv| {
                    for (kv.value_ptr.items) |r| {
                        inline for (expected_results) |e| {
                            if (Range.eql(r, e)) break;
                        } else return error.SearchMismatch;
                    }
                }
            }
            {
                const res = try tree.search(t.allocator, Range.initSingle(0, 0));
                defer t.allocator.free(res);

                const expected_results = .{
                    Range.initSingle(500, 500),
                    Range.initSingle(500, 501),
                    Range.initSingle(500, 502),
                };

                for (res) |kv| {
                    for (kv.value_ptr.items) |r| {
                        inline for (expected_results) |e| {
                            if (Range.eql(r, e)) break;
                        } else return error.SearchMismatch;
                    }
                }
            }
            {
                const res = try tree.search(t.allocator, Range.initSingle(5, 5));
                defer t.allocator.free(res);

                const expected_results = .{
                    Range.initSingle(502, 500),
                    Range.initSingle(502, 501),
                    Range.initSingle(502, 502),
                    Range.initSingle(502, 503),
                    Range.initSingle(502, 504),
                    Range.initSingle(502, 505),
                    Range.initSingle(503, 500),
                    Range.initSingle(503, 501),
                };
                for (res) |kv| {
                    for (kv.value_ptr.items) |r| {
                        inline for (expected_results) |e| {
                            if (Range.eql(r, e)) break;
                        } else return error.SearchMismatch;
                    }
                }
            }
            {
                const res = try tree.search(t.allocator, Range.initSingle(11, 11));
                try t.expectEqualSlices(Tree.SearchItem, &.{}, res);
            }

            {
                // Check that it contains all ranges
                const res = try tree.search(t.allocator, Range.init(0, 0, 500, 500));
                defer t.allocator.free(res);
                for (res) |kv| {
                    data_loop: inline for (data) |d| {
                        inline for (d[1]) |range| {
                            for (kv.value_ptr.items) |r|
                                if (range.eql(r)) break :data_loop;
                        }
                    } else return error.SearchMismatch;
                }
            }
        }

        test "DependentTree2" {
            const t = std.testing;

            var r: Self = .{};
            defer r.deinit(t.allocator);

            const bound = 15;

            for (0..bound) |i| {
                for (0..bound) |j| {
                    const key = Range.initSingle(@intCast(i), @intCast(j));
                    const value = Range.initSingle(@intCast(bound - i - 1), @intCast(bound - j - 1));
                    try r.put(t.allocator, key, value);
                    std.testing.expect(r.rtree.root.getSingle(key) != null) catch |err| {
                        std.debug.print("{}\n", .{r.rtree.root});
                        std.debug.print("{}\n", .{key});
                        return err;
                    };
                    try r.put(t.allocator, key, value);
                    try std.testing.expect(r.rtree.root.getSingle(key) != null);
                }
            }

            for (0..bound) |i| {
                for (0..bound) |j| {
                    // Ensure no duplicate keys are present
                    const range = Range.initSingle(@intCast(i), @intCast(j));
                    const res = try r.search(t.allocator, range);
                    defer t.allocator.free(res);
                    std.testing.expectEqual(@as(usize, 1), res.len) catch |err| {
                        std.debug.print("Range: {}\n", .{range});
                        return err;
                    };
                }
            }

            for (0..bound) |i| {
                for (0..bound) |j| {
                    try r.removeValue(
                        t.allocator,
                        Range.initSingle(@intCast(bound - i - 1), @intCast(bound - j - 1)),
                        Range.initSingle(@intCast(i), @intCast(j)),
                    );
                    try r.removeValue(
                        t.allocator,
                        Range.initSingle(@intCast(bound - i - 1), @intCast(bound - j - 1)),
                        Range.initSingle(@intCast(i), @intCast(j)),
                    );
                }
            }
        }
    };
}
