const std = @import("std");

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const Mat4 = [4][4]f32;

pub fn degreesToRadians(degrees: f32) f32 {
    return degrees * std.math.pi / 180.0;
}

pub fn identity() Mat4 {
    return .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
}

pub fn multiply(a: *const Mat4, b: *const Mat4) Mat4 {
    var result: Mat4 = undefined;
    for (0..4) |c| {
        for (0..4) |r| {
            result[c][r] = 0;
            for (0..4) |k| {
                result[c][r] += a[k][r] * b[c][k];
            }
        }
    }
    return result;
}

pub fn rotateY(base: *const Mat4, angle: f32) Mat4 {
    const s = @sin(angle);
    const c = @cos(angle);
    const rotation: Mat4 = .{
        .{ c, 0, s, 0 },
        .{ 0, 1, 0, 0 },
        .{ -s, 0, c, 0 },
        .{ 0, 0, 0, 1 },
    };
    return multiply(base, &rotation);
}

pub fn perspective(y_fov: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const a = 1.0 / @tan(y_fov / 2.0);
    return .{
        .{ a / aspect, 0, 0, 0 },
        .{ 0, a, 0, 0 },
        .{ 0, 0, -((far + near) / (far - near)), -1 },
        .{ 0, 0, -((2.0 * far * near) / (far - near)), 0 },
    };
}

pub fn invert(m: Mat4) Mat4 {
    var a: [16]f32 = undefined;
    for (0..4) |c| {
        for (0..4) |r| {
            a[c * 4 + r] = m[c][r];
        }
    }

    var inv: [16]f32 = undefined;
    inv[0] = a[5] * a[10] * a[15] - a[5] * a[11] * a[14] - a[9] * a[6] * a[15] + a[9] * a[7] * a[14] + a[13] * a[6] * a[11] - a[13] * a[7] * a[10];
    inv[4] = -a[4] * a[10] * a[15] + a[4] * a[11] * a[14] + a[8] * a[6] * a[15] - a[8] * a[7] * a[14] - a[12] * a[6] * a[11] + a[12] * a[7] * a[10];
    inv[8] = a[4] * a[9] * a[15] - a[4] * a[11] * a[13] - a[8] * a[5] * a[15] + a[8] * a[7] * a[13] + a[12] * a[5] * a[11] - a[12] * a[7] * a[9];
    inv[12] = -a[4] * a[9] * a[14] + a[4] * a[10] * a[13] + a[8] * a[5] * a[14] - a[8] * a[6] * a[13] - a[12] * a[5] * a[10] + a[12] * a[6] * a[9];
    inv[1] = -a[1] * a[10] * a[15] + a[1] * a[11] * a[14] + a[9] * a[2] * a[15] - a[9] * a[3] * a[14] - a[13] * a[2] * a[11] + a[13] * a[3] * a[10];
    inv[5] = a[0] * a[10] * a[15] - a[0] * a[11] * a[14] - a[8] * a[2] * a[15] + a[8] * a[3] * a[14] + a[12] * a[2] * a[11] - a[12] * a[3] * a[10];
    inv[9] = -a[0] * a[9] * a[15] + a[0] * a[11] * a[13] + a[8] * a[1] * a[15] - a[8] * a[3] * a[13] - a[12] * a[1] * a[11] + a[12] * a[3] * a[9];
    inv[13] = a[0] * a[9] * a[14] - a[0] * a[10] * a[13] - a[8] * a[1] * a[14] + a[8] * a[2] * a[13] + a[12] * a[1] * a[10] - a[12] * a[2] * a[9];
    inv[2] = a[1] * a[6] * a[15] - a[1] * a[7] * a[14] - a[5] * a[2] * a[15] + a[5] * a[3] * a[14] + a[13] * a[2] * a[7] - a[13] * a[3] * a[6];
    inv[6] = -a[0] * a[6] * a[15] + a[0] * a[7] * a[14] + a[4] * a[2] * a[15] - a[4] * a[3] * a[14] - a[12] * a[2] * a[7] + a[12] * a[3] * a[6];
    inv[10] = a[0] * a[5] * a[15] - a[0] * a[7] * a[13] - a[4] * a[1] * a[15] + a[4] * a[3] * a[13] + a[12] * a[1] * a[7] - a[12] * a[3] * a[5];
    inv[14] = -a[0] * a[5] * a[14] + a[0] * a[6] * a[13] + a[4] * a[1] * a[14] - a[4] * a[2] * a[13] - a[12] * a[1] * a[6] + a[12] * a[2] * a[5];
    inv[3] = -a[1] * a[6] * a[11] + a[1] * a[7] * a[10] + a[5] * a[2] * a[11] - a[5] * a[3] * a[10] - a[9] * a[2] * a[7] + a[9] * a[3] * a[6];
    inv[7] = a[0] * a[6] * a[11] - a[0] * a[7] * a[10] - a[4] * a[2] * a[11] + a[4] * a[3] * a[10] + a[8] * a[2] * a[7] - a[8] * a[3] * a[6];
    inv[11] = -a[0] * a[5] * a[11] + a[0] * a[7] * a[9] + a[4] * a[1] * a[11] - a[4] * a[3] * a[9] - a[8] * a[1] * a[7] + a[8] * a[3] * a[5];
    inv[15] = a[0] * a[5] * a[10] - a[0] * a[6] * a[9] - a[4] * a[1] * a[10] + a[4] * a[2] * a[9] + a[8] * a[1] * a[6] - a[8] * a[2] * a[5];

    const det = a[0] * inv[0] + a[1] * inv[4] + a[2] * inv[8] + a[3] * inv[12];
    const inv_det = if (det != 0.0) 1.0 / det else 0.0;

    var out: Mat4 = undefined;
    for (0..4) |c| {
        for (0..4) |r| {
            out[c][r] = inv[c * 4 + r] * inv_det;
        }
    }
    return out;
}

pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
    const f = normalize(sub(center, eye));
    const s = normalize(cross(f, up));
    const t = cross(s, f);

    var result: Mat4 = .{
        .{ s.x, t.x, -f.x, 0 },
        .{ s.y, t.y, -f.y, 0 },
        .{ s.z, t.z, -f.z, 0 },
        .{ 0, 0, 0, 1 },
    };
    translateInPlace(&result, -eye.x, -eye.y, -eye.z);
    return result;
}

fn translateInPlace(matrix: *Mat4, x: f32, y: f32, z: f32) void {
    const t = [4]f32{ x, y, z, 0 };
    for (0..4) |i| {
        const row = [4]f32{
            matrix[0][i],
            matrix[1][i],
            matrix[2][i],
            matrix[3][i],
        };
        matrix[3][i] += dot4(row, t);
    }
}

fn dot4(a: [4]f32, b: [4]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{
        .x = a.x - b.x,
        .y = a.y - b.y,
        .z = a.z - b.z,
    };
}

fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x,
    };
}

fn dot3(a: Vec3, b: Vec3) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

fn normalize(v: Vec3) Vec3 {
    const inv_len = 1.0 / @sqrt(dot3(v, v));
    return .{
        .x = v.x * inv_len,
        .y = v.y * inv_len,
        .z = v.z * inv_len,
    };
}
