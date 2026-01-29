const std = @import("std");
const ziggy = @import("ziggy");

// GF(2^8) with primitive poly 0x11d
var exp_tbl: [512]u8 = undefined;
var log_tbl: [256]u8 = undefined;

pub fn gogo() !void {
    // 2 data shards, each 3 bytes long
    var d0 = [_]u8{ 'h', 'e', 'l' };
    var d1 = [_]u8{ 'l', 'o', '!' };
    var data = [_][]const u8{ &d0, &d1 };

    // 2 parity shards, each 3 bytes long
    var p0 = [_]u8{0} ** 3;
    var p1 = [_]u8{0} ** 3;
    var parity = [_][]u8{ &p0, &p1 };

    encode(2, 4, &data, &parity);

    std.debug.print("parity[0]: {any}\n", .{p0});
    std.debug.print("parity[1]: {any}\n", .{p1});

    // assert encoded and decoded data are same
    var shards = [_][]const u8{ &d0, &d1, &p0, &p1 };
    var indices = [_]u8{ 0, 1, 2, 3 };
    var o0 = [_]u8{0} ** 3;
    var o1 = [_]u8{0} ** 3;
    var out = [_][]u8{ &o0, &o1 };
    try decode(2, &shards, &indices, &out);
    std.debug.print("decoded[0]: {any}\n", .{out[0]});
    std.debug.print("decoded[1]: {any}\n", .{out[1]});
}

pub fn init() void {
    var x: u16 = 1;
    for (0..255) |i| {
        exp_tbl[i] = @truncate(x);
        log_tbl[@intCast(x & 0xFF)] = @truncate(i);
        x <<= 1;
        if (x & 0x100 != 0) x ^= 0x11d;
    }
    // std.debug.print("{any} \n", .{exp_tbl});

    for (255..512) |i| exp_tbl[i] = exp_tbl[i - 255];
}

inline fn mul(a: u8, b: u8) u8 {
    return if (a == 0 or b == 0) 0 else exp_tbl[@as(u16, log_tbl[a]) + log_tbl[b]];
}

inline fn div(a: u8, b: u8) u8 {
    return if (a == 0) 0 else exp_tbl[@as(u16, log_tbl[a]) + 255 - log_tbl[b]];
}

// Encode k data shards -> n-k parity shards
pub fn encode(comptime k: usize, comptime n: usize, data: *const [k][]const u8, parity: *[n - k][]u8) void {
    const len = data[0].len;
    for (0..n - k) |p| {
        @memset(parity[p], 0);
        for (0..len) |i| {
            for (0..k) |j| {
                parity[p][i] ^= mul(exp_tbl[(p + k) * j % 255], data[j][i]);
            }
        }
    }
}

// Decode: given any k shards with indices, recover all k data shards
pub fn decode(comptime k: usize, shards: []const []const u8, indices: []const u8, out: [][]u8) !void {
    if (shards.len < k or indices.len < k) return error.NotEnoughShards;
    const len = shards[0].len;

    // Build Vandermonde submatrix and invert via Gaussian elimination
    var mat: [k][k]u8 = undefined;
    var inv: [k][k]u8 = undefined;
    for (0..k) |i| {
        for (0..k) |j| {
            mat[i][j] = exp_tbl[@as(u16, indices[i]) * j % 255];
            inv[i][j] = if (i == j) 1 else 0;
        }
    }

    // Gauss-Jordan
    for (0..k) |col| {
        var pivot = col;
        while (pivot < k and mat[pivot][col] == 0) pivot += 1;
        if (pivot == k) return error.SingularMatrix;
        std.mem.swap([k]u8, &mat[col], &mat[pivot]);
        std.mem.swap([k]u8, &inv[col], &inv[pivot]);

        const scale = div(1, mat[col][col]);
        for (0..k) |j| {
            mat[col][j] = mul(mat[col][j], scale);
            inv[col][j] = mul(inv[col][j], scale);
        }
        for (0..k) |row| {
            if (row != col and mat[row][col] != 0) {
                const f = mat[row][col];
                for (0..k) |j| {
                    mat[row][j] ^= mul(f, mat[col][j]);
                    inv[row][j] ^= mul(f, inv[col][j]);
                }
            }
        }
    }

    // Multiply inverse by data
    for (0..len) |i| {
        for (0..k) |r| {
            var acc: u8 = 0;
            for (0..k) |c| acc ^= mul(inv[r][c], shards[c][i]);
            out[r][i] = acc;
        }
    }
}

pub fn main() !void {
    init();
    try gogo();
}

test "idk lel" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) !void {
            std.debug.print("{any}\n", .{input});
        }
    }.testOne, .{});
}
