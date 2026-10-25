const std = @import("std");
const testing = std.testing;

// 12 bytes
pub const Header = struct {
    id: u16,
    qr: u1,
    opcode: u4,
    aa: u1,
    tc: u1,
    rd: u1,
    ra: u1,
    z: u1,
    ad: u1,
    cd: u1,
    rcode: u4,
    qdcount: u16,
    ancount: u16,
    nscount: u16,
    arcount: u16,

    pub fn encodeHeader(h: Header, buffer_header: *[12]u8) usize {
        std.mem.writeInt(u16, buffer_header[0..2], h.id, .big);

        var flags: u16 = 0;

        const arr_flags = [7]u1{ h.aa, h.tc, h.rd, h.ra, h.z, h.ad, h.cd };
        const bit_pos = [7]u4{ 10, 9, 8, 7, 6, 5, 4 };

        flags |= @as(u16, @intCast(h.qr)) << 15;
        flags |= @as(u16, @intCast(h.opcode)) << 11;

        for (arr_flags, bit_pos) |flag, pos| {
            flags |= @as(u16, @intCast(flag)) << pos;
        }

        flags |= @as(u16, @intCast(h.rcode)) << 0;

        std.mem.writeInt(u16, buffer_header[2..4], flags, .big);
        std.mem.writeInt(u16, buffer_header[4..6], h.qdcount, .big);
        std.mem.writeInt(u16, buffer_header[6..8], h.ancount, .big);
        std.mem.writeInt(u16, buffer_header[8..10], h.nscount, .big);
        std.mem.writeInt(u16, buffer_header[10..12], h.arcount, .big);

        return 12;
    }

    pub fn decodeHeader(buffer: *const [12]u8) Header {
        const id = std.mem.readInt(u16, buffer[0..2], .big);

        const flags = std.mem.readInt(u16, buffer[2..4], .big);

        const qr = @as(u1, @intCast(flags >> 15));
        const opcode = @as(u4, @intCast((flags >> 11) & 0x0F));

        const bit_pos = [7]u4{ 10, 9, 8, 7, 6, 5, 4 };
        var arr_flags: [7]u1 = undefined;

        for (&arr_flags, bit_pos) |*flag, pos| {
            flag.* = @as(u1, @intCast((flags >> pos) & 0x01));
        }

        const rcode = @as(u4, @intCast(flags & 0x0F));

        const qdcount = std.mem.readInt(u16, buffer[4..6], .big);
        const ancount = std.mem.readInt(u16, buffer[6..8], .big);
        const nscount = std.mem.readInt(u16, buffer[8..10], .big);
        const arcount = std.mem.readInt(u16, buffer[10..12], .big);

        return .{
            .id = id,
            .qr = qr,
            .opcode = opcode,
            .aa = arr_flags[0],
            .tc = arr_flags[1],
            .rd = arr_flags[2],
            .ra = arr_flags[3],
            .z = arr_flags[4],
            .ad = arr_flags[5],
            .cd = arr_flags[6],
            .rcode = rcode,
            .qdcount = qdcount,
            .ancount = ancount,
            .nscount = nscount,
            .arcount = arcount,
        };
    }
};

pub const Question = struct {
    qname: []const []const u8,
    qtype: u16, // 1 for A, 12 for ptr, etc etc
    qclass: u16, // In
};

// For Answer, Authority, Additional
pub const ResourceRecord = struct {
    name: []const []const u8,
    rtype: u16,
    rclass: u16,
    ttl: u32,
    rdata: []const u8,
};

pub const Message = struct {
    header: Header,
    questions: []Question,
    answers: []ResourceRecord,
    authorities: []ResourceRecord,
    additionals: []ResourceRecord,
};

pub fn encodeServiceInstanceName(labels: []const []const u8, out: []u8) !usize {
    var seek: usize = 0;

    for (labels) |s| {
        if (s.len > 63) return error.LabelTooLong;
        if (seek + 1 + s.len > out.len) return error.NoSpace;

        out[seek] = @intCast(s.len);
        seek += 1;

        @memcpy(out[seek .. seek + s.len], s);
        seek += s.len;
    }

    if (seek + 1 > out.len) return error.NoSpace;
    out[seek] = 0x00;
    seek += 1;

    return seek;
}

pub fn decodeServiceInstanceName(in: []const u8, out: []u8) !usize {
    var s_pos: usize = 0;
    var d_pos: usize = 0;

    while (true) {
        if (s_pos >= in.len) return error.Truncated;
        const label_len: usize = in[s_pos];

        if (label_len == 0) return s_pos + 1;

        if (s_pos + 1 + label_len > in.len) return error.Truncated;
        if (d_pos + label_len > out.len) return error.NoSpace;

        @memcpy(out[d_pos .. d_pos + label_len], in[s_pos + 1 .. s_pos + 1 + label_len]);

        d_pos += label_len;
        s_pos += 1 + label_len;
    }
}

/// Print bits of six fields of header section
pub fn dumpHeader(buffer: *const [12]u8) void {
    std.debug.print("Id:\t\t{b:0>8}", .{buffer[0]});
    std.debug.print("{b:0>8}\n", .{buffer[1]});

    const flags = std.mem.readInt(u16, buffer[2..4], .big);
    std.debug.print("Flags:\t\t{b:0>16}\n", .{flags});

    const counts = [4][]const u8{ "qdcount", "ancount", "nscount", "arcount" };
    for (counts, 0..) |name, i| {
        const off = 4 + i * 2;
        const val = std.mem.readInt(u16, buffer[off..][0..2], .big);
        std.debug.print("{s}:\t{b:0>16}\n", .{ name, val });
    }
}

// Tests

// Header
test "Header: all bits in 0" {
    const h = Header{
        .id = 0,
        .qr = 0,
        .opcode = 0,
        .aa = 0,
        .tc = 0,
        .rd = 0,
        .ra = 0,
        .z = 0,
        .ad = 0,
        .cd = 0,
        .rcode = 0,
        .qdcount = 0,
        .ancount = 0,
        .nscount = 0,
        .arcount = 0,
    };

    var buffer: [12]u8 = undefined;
    const len = h.encodeHeader(&buffer);

    try testing.expectEqual(@as(usize, 12), len);
    try testing.expectEqualSlices(u8, &[12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &buffer);
}

test "Header: all bits in 1" {
    const h = Header{
        .id = 0x1234,
        .qr = 1,
        .opcode = 15,
        .aa = 1,
        .tc = 1,
        .rd = 1,
        .ra = 1,
        .z = 1,
        .ad = 1,
        .cd = 1,
        .rcode = 15,
        .qdcount = 0xABCD,
        .ancount = 0x1234,
        .nscount = 0x5678,
        .arcount = 0x9EF0,
    };

    var buffer: [12]u8 = undefined;
    _ = h.encodeHeader(&buffer);

    const expected = [12]u8{
        0x12, 0x34, // id
        0xFF, 0xFF, // flags
        0xAB, 0xCD, // qdcount
        0x12, 0x34, // ancount
        0x56, 0x78, // nscount
        0x9E, 0xF0, // arcount
    };

    try testing.expectEqualSlices(u8, &expected, &buffer);
}

test "Header: Simulate sending a dns query" {
    const h = Header{
        .id = 0,
        .qr = 0,
        .opcode = 0,
        .aa = 0,
        .tc = 0,
        .rd = 0,
        .ra = 0,
        .z = 0,
        .ad = 0,
        .cd = 0,
        .rcode = 0,
        .qdcount = 1,
        .ancount = 0,
        .nscount = 0,
        .arcount = 0,
    };

    var buffer: [12]u8 = undefined;
    _ = h.encodeHeader(&buffer);

    const expected = [12]u8{
        0x00, 0x00, // id
        0x00, 0x00, // flags
        0x00, 0x01, // qdcount
        0x00, 0x00, // ancount
        0x00, 0x00, // nscount
        0x00, 0x00, // arcount
    };

    try testing.expectEqualSlices(u8, &expected, &buffer);
}

test "Header: all fields with unique value" {
    const original = Header{
        .id = 0x1234,
        .qr = 1,
        .opcode = 10,
        .aa = 1,
        .tc = 0,
        .rd = 1,
        .ra = 0,
        .z = 1,
        .ad = 0,
        .cd = 1,
        .rcode = 5,
        .qdcount = 3,
        .ancount = 1,
        .nscount = 2,
        .arcount = 4,
    };

    var buffer: [12]u8 = undefined;
    const len = original.encodeHeader(&buffer);
    try testing.expectEqual(@as(usize, 12), len);

    const decoded = Header.decodeHeader(&buffer);

    try testing.expectEqualDeep(original, decoded);
}

test "Header: alternating flags" {
    const original = Header{
        .id = 0xBEEF,
        .qr = 1,
        .opcode = 9,
        .aa = 1,
        .tc = 0,
        .rd = 1,
        .ra = 0,
        .z = 1,
        .ad = 0,
        .cd = 1,
        .rcode = 3,
        .qdcount = 0xFFFF,
        .ancount = 0,
        .nscount = 0x8000,
        .arcount = 0x0001,
    };

    var buffer: [12]u8 = undefined;
    _ = original.encodeHeader(&buffer);

    const decoded = Header.decodeHeader(&buffer);

    try testing.expectEqualDeep(original, decoded);
}

// Decode/Encode instances name
const sample_labels = [_][]const u8{ "tanuko", "_chat", "_tcp", "local" };

const sample_wire = [_]u8{
    6,   't', 'a', 'n', 'u', 'k', 'o',
    5,   '_', 'c', 'h', 'a', 't', 4,
    '_', 't', 'c', 'p', 5,   'l', 'o',
    'c', 'a', 'l', 0,
};

const sample_flat = "tanuko_chat_tcplocal";

test "encodeServiceInstanceName: 25 bytes of wire" {
    var out: [64]u8 = undefined;

    const len = try encodeServiceInstanceName(&sample_labels, &out);

    try testing.expectEqual(@as(usize, sample_wire.len), len);
    try testing.expectEqualSlices(u8, &sample_wire, out[0..len]);
}

test "encodeServiceInstanceName: NoSpace" {
    var out: [3]u8 = undefined;
    try testing.expectError(error.NoSpace, encodeServiceInstanceName(&sample_labels, &out));
}

test "decodeServiceInstanceName: Empty input" {
    var out: [64]u8 = undefined;
    try testing.expectError(error.Truncated, decodeServiceInstanceName(&[_]u8{}, &out));
}

test "decodeServiceInstanceName: Truncated label" {
    const wire = [_]u8{ 3, 'a', 'b' };
    var out: [64]u8 = undefined;
    try testing.expectError(error.Truncated, decodeServiceInstanceName(&wire, &out));
}

test "decodeServiceInstanceName: No terminator" {
    const wire = [_]u8{ 3, 'a', 'b', 'c' };
    var out: [64]u8 = undefined;
    try testing.expectError(error.Truncated, decodeServiceInstanceName(&wire, &out));
}

test "decodeServiceInstanceName: NoSpace" {
    const wire = [_]u8{ 3, 'a', 'b', 'c', 0 };
    var out: [2]u8 = undefined;
    try testing.expectError(error.NoSpace, decodeServiceInstanceName(&wire, &out));
}
