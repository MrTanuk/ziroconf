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

    pub fn encodeQuestion(q: Question, out: []u8) !usize {
        const offset = try encodeName(q.qname, out);
        if (out.len < offset + 4) return error.NoSpace;

        std.mem.writeInt(u16, out[offset..][0..2], q.qtype, .big);
        std.mem.writeInt(u16, out[offset + 2 ..][0..2], q.qclass, .big);

        return offset + 4;
    }

    pub fn decodeQuestion(buffer: []const u8, out: [][]const u8) !struct { question: Question, consumed: usize } {
        const data = try decodeName(buffer, out);

        if (buffer.len < data.consumed + 4) return error.Truncated;

        const qtype = std.mem.readInt(u16, buffer[data.consumed..][0..2], .big);
        const qclass = std.mem.readInt(u16, buffer[data.consumed + 2 ..][0..2], .big);

        return .{
            .question = .{
                .qname = out[0..data.count],
                .qtype = qtype,
                .qclass = qclass,
            },
            .consumed = data.consumed + 4,
        };
    }
};

// For Answer, Authority, Additional
pub const ResourceRecord = struct {
    name: []const []const u8,
    rtype: u16,
    rclass: u16,
    ttl: u32,
    rdata: []const u8,

    pub fn encodeResourceRecord(record: ResourceRecord, out: []u8) !usize {
        if (record.rdata.len > 0xFFFF) return error.RdataTooLong;
        const rdata_len = @as(u16, @intCast(record.rdata.len));

        const offset = try encodeName(record.name, out);
        if (out.len < offset + 10 + record.rdata.len) return error.NoSpace;

        std.mem.writeInt(u16, out[offset..][0..2], record.rtype, .big);
        std.mem.writeInt(u16, out[offset + 2 ..][0..2], record.rclass, .big);
        std.mem.writeInt(u32, out[offset + 4 ..][0..4], record.ttl, .big);
        std.mem.writeInt(u16, out[offset + 8 ..][0..2], rdata_len, .big);

        @memcpy(out[offset + 10 ..][0..rdata_len], record.rdata);

        return offset + 10 + rdata_len;
    }

    pub fn decodeResourceRecord(buffer: []const u8, out: [][]const u8) !struct { record: ResourceRecord, consumed: usize } {
        const data = try decodeName(buffer, out);

        if (buffer.len < data.consumed + 10) return error.Truncated;

        const rtype = std.mem.readInt(u16, buffer[data.consumed..][0..2], .big);
        const rclass = std.mem.readInt(u16, buffer[data.consumed + 2 ..][0..2], .big);
        const ttl = std.mem.readInt(u32, buffer[data.consumed + 4 ..][0..4], .big);
        const rdlength = std.mem.readInt(u16, buffer[data.consumed + 8 ..][0..2], .big);

        if (buffer.len < data.consumed + 10 + rdlength) return error.Truncated;

        const rdata = buffer[data.consumed + 10 ..][0..rdlength];

        return .{
            .record = .{
                .name = out[0..data.count],
                .rtype = rtype,
                .rclass = rclass,
                .ttl = ttl,
                .rdata = rdata,
            },
            .consumed = data.consumed + 10 + rdlength,
        };
    }
};

pub const Message = struct {
    header: Header,
    questions: []Question,
    answers: []ResourceRecord,
    authorities: []ResourceRecord,
    additionals: []ResourceRecord,
};

pub fn encodeName(labels: []const []const u8, out: []u8) !usize {
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

pub fn decodeName(name: []const u8, out: [][]const u8) !struct { consumed: usize, count: usize } {
    var s_pos: usize = 0;
    var i: usize = 0;

    while (true) : (i += 1) {
        if (s_pos >= name.len) return error.Truncated;
        const label_len: usize = name[s_pos];

        if (label_len == 0) break;
        if (s_pos + 1 + label_len > name.len) return error.Truncated;

        if (i >= out.len) return error.NoSpace;
        out[i] = name[s_pos + 1 .. s_pos + 1 + label_len];
        s_pos += 1 + label_len;
    }

    return .{ .consumed = s_pos + 1, .count = i };
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

// Name tests

const sample_labels = [_][]const u8{ "tanuko", "_chat", "_tcp", "local" };

const sample_wire = [_]u8{
    6,   't', 'a', 'n', 'u', 'k', 'o',
    5,   '_', 'c', 'h', 'a', 't', 4,
    '_', 't', 'c', 'p', 5,   'l', 'o',
    'c', 'a', 'l', 0,
};

const sample_flat = "tanuko_chat_tcplocal";

test "encodeName: 25 bytes of wire" {
    var out: [64]u8 = undefined;

    const len = try encodeName(&sample_labels, &out);

    try testing.expectEqual(@as(usize, sample_wire.len), len);
    try testing.expectEqualSlices(u8, &sample_wire, out[0..len]);
}

test "encodeName: NoSpace" {
    var out: [3]u8 = undefined;
    try testing.expectError(error.NoSpace, encodeName(&sample_labels, &out));
}

test "decodeName: Empty input" {
    var out: [10][]const u8 = undefined;
    try testing.expectError(error.Truncated, decodeName(&[_]u8{}, &out));
}

test "decodeName: Truncated label" {
    const wire = [_]u8{ 3, 'a', 'b' };
    var out: [10][]const u8 = undefined;
    try testing.expectError(error.Truncated, decodeName(&wire, &out));
}

test "decodeName: No terminator" {
    const wire = [_]u8{ 3, 'a', 'b', 'c' };
    var out: [10][]const u8 = undefined;
    try testing.expectError(error.Truncated, decodeName(&wire, &out));
}

test "decodeName: NoSpace" {
    const wire = [_]u8{ 1, 'a', 1, 'b', 0 };
    var out: [1][]const u8 = undefined;
    try testing.expectError(error.NoSpace, decodeName(&wire, &out));
}

// Question tests

test "Question: Encode" {
    const q = Question{
        .qname = &sample_labels,
        .qtype = 1, // A
        .qclass = 1, // IN
    };

    var buf: [256]u8 = undefined;
    const len = try q.encodeQuestion(&buf);

    const expected = sample_wire ++ [4]u8{ 0x00, 0x01, 0x00, 0x01 };

    try testing.expectEqual(@as(usize, expected.len), len);
    try testing.expectEqualSlices(u8, &expected, buf[0..len]);
}

test "Question: Decode" {
    const wire = sample_wire ++ [4]u8{ 0x00, 0x01, 0x00, 0x01 };

    var slices: [16][]const u8 = undefined;
    const data_question = try Question.decodeQuestion(&wire, &slices);
    const q = data_question.question;

    try testing.expectEqual(@as(usize, 4), q.qname.len);
    try testing.expectEqualStrings("tanuko", q.qname[0]);
    try testing.expectEqualStrings("_chat", q.qname[1]);
    try testing.expectEqualStrings("_tcp", q.qname[2]);
    try testing.expectEqualStrings("local", q.qname[3]);
    try testing.expectEqual(@as(u16, 1), q.qtype);
    try testing.expectEqual(@as(u16, 1), q.qclass);
}

test "Question: round-trip" {
    const original = Question{
        .qname = &sample_labels,
        .qtype = 12, // PTR
        .qclass = 1,
    };

    var buf: [256]u8 = undefined;
    const written = try original.encodeQuestion(&buf);

    var slices: [16][]const u8 = undefined;
    const data_question = try Question.decodeQuestion(buf[0..written], &slices);
    const decoded = data_question.question;

    try testing.expectEqual(original.qtype, decoded.qtype);
    try testing.expectEqual(original.qclass, decoded.qclass);
    try testing.expectEqual(original.qname.len, decoded.qname.len);
    for (original.qname, decoded.qname) |a, b| {
        try testing.expectEqualStrings(a, b);
    }

    try testing.expectEqual(written, data_question.consumed);
}

test "Question: decode — truncated qtype" {
    const wire = sample_wire ++ [1]u8{0x00};

    var slices: [16][]const u8 = undefined;
    try testing.expectError(error.Truncated, Question.decodeQuestion(&wire, &slices));
}

test "Question: decode — truncated qclass" {
    const wire = sample_wire ++ [3]u8{ 0x00, 0x01, 0x00 };

    var slices: [16][]const u8 = undefined;
    try testing.expectError(error.Truncated, Question.decodeQuestion(&wire, &slices));
}

test "Question: encode — NoSpace" {
    const q = Question{
        .qname = &sample_labels,
        .qtype = 1,
        .qclass = 1,
    };
    var buf: [28]u8 = undefined;
    try testing.expectError(error.NoSpace, q.encodeQuestion(&buf));
}

// ResourceRecord tests
const sample_rdata = [_]u8{ 192, 168, 1, 1 }; // A record: 192.168.1.1

test "ResourceRecord: golden — encode" {
    const rr = ResourceRecord{
        .name   = &sample_labels,
        .rtype  = 1,         // A
        .rclass = 1,         // IN
        .ttl    = 0x12345678,
        .rdata  = &sample_rdata,
    };

    var buf: [256]u8 = undefined;
    const written = try rr.encodeResourceRecord(&buf);

    const expected = sample_wire ++ [14]u8{
        0x00, 0x01,             // rtype  = 1 (A)
        0x00, 0x01,             // rclass = 1 (IN)
        0x12, 0x34, 0x56, 0x78, // ttl    = 0x12345678 (big-endian)
        0x00, 0x04,             // rdlength = 4 (rdata.len)
        0xC0, 0xA8, 0x01, 0x01, // rdata: 192.168.1.1
    };

    try testing.expectEqual(@as(usize, expected.len), written);
    try testing.expectEqualSlices(u8, &expected, buf[0..written]);
}

test "ResourceRecord: golden — decode" {
    const wire = sample_wire ++ [14]u8{
        0x00, 0x01,
        0x00, 0x01,
        0x12, 0x34, 0x56, 0x78,
        0x00, 0x04,
        0xC0, 0xA8, 0x01, 0x01,
    };

    var slices: [16][]const u8 = undefined;
    const data_rr = try ResourceRecord.decodeResourceRecord(&wire, &slices);
    const rr = data_rr.record;

    try testing.expectEqual(@as(usize, 4), rr.name.len);
    try testing.expectEqualStrings("tanuko", rr.name[0]);
    try testing.expectEqualStrings("_chat",  rr.name[1]);
    try testing.expectEqualStrings("_tcp",   rr.name[2]);
    try testing.expectEqualStrings("local",  rr.name[3]);
    try testing.expectEqual(@as(u16, 1), rr.rtype);
    try testing.expectEqual(@as(u16, 1), rr.rclass);
    try testing.expectEqual(@as(u32, 0x12345678), rr.ttl);
    try testing.expectEqualSlices(u8, &sample_rdata, rr.rdata);
    try testing.expectEqual(@as(usize, wire.len), data_rr.consumed);
}

test "ResourceRecord: round-trip" {
    const original = ResourceRecord{
        .name   = &sample_labels,
        .rtype  = 1,
        .rclass = 1,
        .ttl    = 0x12345678,
        .rdata  = &sample_rdata,
    };

    var buf: [256]u8 = undefined;
    const written = try original.encodeResourceRecord(&buf);

    var slices: [16][]const u8 = undefined;
    const data_rr = try ResourceRecord.decodeResourceRecord(buf[0..written], &slices);
    const decoded = data_rr.record;

    try testing.expectEqual(original.name.len, decoded.name.len);
    for (original.name, decoded.name) |a, b| {
        try testing.expectEqualStrings(a, b);
    }
    try testing.expectEqual(original.rtype,  decoded.rtype);
    try testing.expectEqual(original.rclass, decoded.rclass);
    try testing.expectEqual(original.ttl,    decoded.ttl);
    try testing.expectEqualSlices(u8, original.rdata, decoded.rdata);
    try testing.expectEqual(written, data_rr.consumed);
}

