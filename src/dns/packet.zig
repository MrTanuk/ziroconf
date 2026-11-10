const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;

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

    pub fn encodeHeader(self: Header, out: *[12]u8) usize {
        std.mem.writeInt(u16, out[0..2], self.id, .big);

        var flags: u16 = 0;

        const arr_flags = [7]u1{ self.aa, self.tc, self.rd, self.ra, self.z, self.ad, self.cd };
        const bit_pos = [7]u4{ 10, 9, 8, 7, 6, 5, 4 };

        flags |= @as(u16, self.qr) << 15;
        flags |= @as(u16, self.opcode) << 11;

        for (arr_flags, bit_pos) |flag, pos| {
            flags |= @as(u16, flag) << pos;
        }

        flags |= @as(u16, self.rcode) << 0;

        std.mem.writeInt(u16, out[2..4], flags, .big);
        std.mem.writeInt(u16, out[4..6], self.qdcount, .big);
        std.mem.writeInt(u16, out[6..8], self.ancount, .big);
        std.mem.writeInt(u16, out[8..10], self.nscount, .big);
        std.mem.writeInt(u16, out[10..12], self.arcount, .big);

        return 12;
    }

    pub fn decodeHeader(wire: *const [12]u8) Header {
        const id = std.mem.readInt(u16, wire[0..2], .big);

        const flags = std.mem.readInt(u16, wire[2..4], .big);

        const qr = @as(u1, @intCast(flags >> 15));
        const opcode = @as(u4, @intCast((flags >> 11) & 0x0F));

        const bit_pos = [7]u4{ 10, 9, 8, 7, 6, 5, 4 };
        var arr_flags: [7]u1 = undefined;

        for (&arr_flags, bit_pos) |*flag, pos| {
            flag.* = @as(u1, @intCast((flags >> pos) & 0x01));
        }

        const rcode = @as(u4, @intCast(flags & 0x0F));

        const qdcount = std.mem.readInt(u16, wire[4..6], .big);
        const ancount = std.mem.readInt(u16, wire[6..8], .big);
        const nscount = std.mem.readInt(u16, wire[8..10], .big);
        const arcount = std.mem.readInt(u16, wire[10..12], .big);

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

    pub const DecodedQuestion = struct { value: Question, consumed: usize };

    pub fn encodeQuestion(self: Question, wire: []u8) !usize {
        const offset = try encodeName(self.qname, wire);
        if (wire.len < offset + 4) return error.NoSpace;

        std.mem.writeInt(u16, wire[offset..][0..2], self.qtype, .big);
        std.mem.writeInt(u16, wire[offset + 2 ..][0..2], self.qclass, .big);

        return offset + 4;
    }

    pub fn decodeQuestion(buffer: []const u8, slices: [][]const u8) !DecodedQuestion {
        const data = try decodeName(buffer, slices);

        if (buffer.len < data.consumed + 4) return error.Truncated;

        const qtype = std.mem.readInt(u16, buffer[data.consumed..][0..2], .big);
        const qclass = std.mem.readInt(u16, buffer[data.consumed + 2 ..][0..2], .big);

        return .{
            .value = .{
                .qname = slices[0..data.label_count],
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

    pub const DecodedRecord = struct { value: ResourceRecord, consumed: usize };

    pub fn encodeResourceRecord(self: ResourceRecord, wire: []u8) !usize {
        if (self.rdata.len > 0xFFFF) return error.RdataTooLong;
        const rdlength = @as(u16, @intCast(self.rdata.len));

        const offset = try encodeName(self.name, wire);
        if (wire.len < offset + 10 + self.rdata.len) return error.NoSpace;

        std.mem.writeInt(u16, wire[offset..][0..2], self.rtype, .big);
        std.mem.writeInt(u16, wire[offset + 2 ..][0..2], self.rclass, .big);
        std.mem.writeInt(u32, wire[offset + 4 ..][0..4], self.ttl, .big);
        std.mem.writeInt(u16, wire[offset + 8 ..][0..2], rdlength, .big);

        @memcpy(wire[offset + 10 ..][0..rdlength], self.rdata);

        return offset + 10 + rdlength;
    }

    pub fn decodeResourceRecord(buffer: []const u8, slices: [][]const u8) !DecodedRecord {
        const data = try decodeName(buffer, slices);

        if (buffer.len < data.consumed + 10) return error.Truncated;

        const rtype = std.mem.readInt(u16, buffer[data.consumed..][0..2], .big);
        const rclass = std.mem.readInt(u16, buffer[data.consumed + 2 ..][0..2], .big);
        const ttl = std.mem.readInt(u32, buffer[data.consumed + 4 ..][0..4], .big);
        const rdlength = std.mem.readInt(u16, buffer[data.consumed + 8 ..][0..2], .big);

        if (buffer.len < data.consumed + 10 + rdlength) return error.Truncated;

        const rdata = buffer[data.consumed + 10 ..][0..rdlength];

        return .{
            .value = .{
                .name = slices[0..data.label_count],
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
    questions: []const Question,
    answers: []const ResourceRecord,
    authorities: []const ResourceRecord,
    additionals: []const ResourceRecord,

    pub fn encodeMessage(self: *const Message, wire: []u8) !usize {
        if (wire.len < 12) return error.NoSpace;

        if (self.questions.len > 0xFFFF or self.answers.len > 0xFFFF or self.authorities.len > 0xFFFF or self.additionals.len > 0xFFFF)
            return error.TooManyItems;

        var h = self.header;

        h.qdcount = @as(u16, @intCast(self.questions.len));
        h.ancount = @as(u16, @intCast(self.answers.len));
        h.nscount = @as(u16, @intCast(self.authorities.len));
        h.arcount = @as(u16, @intCast(self.additionals.len));

        var offset: usize = h.encodeHeader(wire[0..12]);

        for (self.questions) |question| {
            const written = try Question.encodeQuestion(question, wire[offset..]);
            offset += written;
        }

        for (self.answers) |answer| {
            const written = try ResourceRecord.encodeResourceRecord(answer, wire[offset..]);
            offset += written;
        }

        for (self.authorities) |authority| {
            const written = try ResourceRecord.encodeResourceRecord(authority, wire[offset..]);
            offset += written;
        }

        for (self.additionals) |additional| {
            const written = try ResourceRecord.encodeResourceRecord(additional, wire[offset..]);
            offset += written;
        }

        return offset;
    }

    pub fn decodeMessage(allocator: Allocator, wire: []const u8) !Message {
        if (wire.len < 12) return error.Truncated;

        const MAX_LABELS = 10;

        const header = Header.decodeHeader(wire[0..12]);
        var offset: usize = 12;

        const min_bytes = @as(usize, header.qdcount) * 5 + @as(usize, header.ancount) * 11 + @as(usize, header.nscount) * 11 + @as(usize, header.arcount) * 11;

        if (wire.len < 12 + min_bytes) return error.Truncated;

        const questions = try allocator.alloc(Question, @as(usize, header.qdcount));
        const answers = try allocator.alloc(ResourceRecord, @as(usize, header.ancount));
        const authorities = try allocator.alloc(ResourceRecord, @as(usize, header.nscount));
        const additionals = try allocator.alloc(ResourceRecord, @as(usize, header.arcount));

        for (questions) |*qd| {
            const slices = try allocator.alloc([]const u8, MAX_LABELS);
            const decoded_qd = try Question.decodeQuestion(wire[offset..], slices);

            qd.* = decoded_qd.value;
            offset += decoded_qd.consumed;
        }

        for (answers) |*an| {
            const slices = try allocator.alloc([]const u8, MAX_LABELS);
            const decoded_an = try ResourceRecord.decodeResourceRecord(wire[offset..], slices);

            an.* = decoded_an.value;
            offset += decoded_an.consumed;
        }

        for (authorities) |*ns| {
            const slices = try allocator.alloc([]const u8, MAX_LABELS);
            const decoded_ns = try ResourceRecord.decodeResourceRecord(wire[offset..], slices);

            ns.* = decoded_ns.value;
            offset += decoded_ns.consumed;
        }

        for (additionals) |*ar| {
            const slices = try allocator.alloc([]const u8, MAX_LABELS);
            const decoded_ar = try ResourceRecord.decodeResourceRecord(wire[offset..], slices);

            ar.* = decoded_ar.value;
            offset += decoded_ar.consumed;
        }

        if (offset != wire.len) return error.TrailingBytes;

        return .{
            .header = header,
            .questions = questions,
            .answers = answers,
            .authorities = authorities,
            .additionals = additionals,
        };
    }
};

pub fn encodeName(labels: []const []const u8, wire: []u8) !usize {
    var seek: usize = 0;
    var total_length: usize = 0;

    for (labels) |s| {
        if (s.len > 63) return error.LabelTooLong;
        if (seek + 1 + s.len > wire.len) return error.NoSpace;

        total_length += s.len + 1;
        if (total_length + 1 > 255) return error.MaxLengthName;

        wire[seek] = @intCast(s.len);
        seek += 1;

        @memcpy(wire[seek .. seek + s.len], s);
        seek += s.len;
    }

    if (seek + 1 > wire.len) return error.NoSpace;
    wire[seek] = 0x00;
    seek += 1;

    return seek;
}

pub fn decodeName(wire: []const u8, slices: [][]const u8) !struct { consumed: usize, label_count: usize } {
    var s_pos: usize = 0;
    var i: usize = 0;

    while (true) : (i += 1) {
        if (s_pos >= wire.len) return error.Truncated;
        const label_len: usize = wire[s_pos];

        if (label_len == 0) break;
        if (s_pos + 1 + label_len > wire.len) return error.Truncated;
        if (s_pos + 1 + label_len + 1 > 255) return error.MaxLengthName;

        if (i >= slices.len) return error.NoSpace;
        slices[i] = wire[s_pos + 1 .. s_pos + 1 + label_len];
        s_pos += 1 + label_len;
    }

    return .{ .consumed = s_pos + 1, .label_count = i };
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

const sample_name_wire = [_]u8{
    6,   't', 'a', 'n', 'u', 'k', 'o',
    5,   '_', 'c', 'h', 'a', 't', 4,
    '_', 't', 'c', 'p', 5,   'l', 'o',
    'c', 'a', 'l', 0,
};

test "encodeName: 25 bytes of wire" {
    var out: [64]u8 = undefined;

    const len = try encodeName(&sample_labels, &out);

    try testing.expectEqual(@as(usize, sample_name_wire.len), len);
    try testing.expectEqualSlices(u8, &sample_name_wire, out[0..len]);
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

    const expected = sample_name_wire ++ [4]u8{ 0x00, 0x01, 0x00, 0x01 };

    try testing.expectEqual(@as(usize, expected.len), len);
    try testing.expectEqualSlices(u8, &expected, buf[0..len]);
}

test "Question: Decode" {
    const wire = sample_name_wire ++ [4]u8{ 0x00, 0x01, 0x00, 0x01 };

    var slices: [16][]const u8 = undefined;
    const data_question = try Question.decodeQuestion(&wire, &slices);
    const q = data_question.value;

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
    const decoded = data_question.value;

    try testing.expectEqual(original.qtype, decoded.qtype);
    try testing.expectEqual(original.qclass, decoded.qclass);
    try testing.expectEqual(original.qname.len, decoded.qname.len);
    for (original.qname, decoded.qname) |a, b| {
        try testing.expectEqualStrings(a, b);
    }

    try testing.expectEqual(written, data_question.consumed);
}

test "Question: decode — truncated qtype" {
    const wire = sample_name_wire ++ [1]u8{0x00};

    var slices: [16][]const u8 = undefined;
    try testing.expectError(error.Truncated, Question.decodeQuestion(&wire, &slices));
}

test "Question: decode — truncated qclass" {
    const wire = sample_name_wire ++ [3]u8{ 0x00, 0x01, 0x00 };

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
        .name = &sample_labels,
        .rtype = 1, // A
        .rclass = 1, // IN
        .ttl = 0x12345678,
        .rdata = &sample_rdata,
    };

    var buf: [256]u8 = undefined;
    const written = try rr.encodeResourceRecord(&buf);

    const expected = sample_name_wire ++ [14]u8{
        0x00, 0x01, // rtype  = 1 (A)
        0x00, 0x01, // rclass = 1 (IN)
        0x12, 0x34, 0x56, 0x78, // ttl    = 0x12345678 (big-endian)
        0x00, 0x04, // rdlength = 4 (rdata.len)
        0xC0, 0xA8, 0x01, 0x01, // rdata: 192.168.1.1
    };

    try testing.expectEqual(@as(usize, expected.len), written);
    try testing.expectEqualSlices(u8, &expected, buf[0..written]);
}

test "ResourceRecord: golden — decode" {
    const wire = sample_name_wire ++ [14]u8{
        0x00, 0x01,
        0x00, 0x01,
        0x12, 0x34,
        0x56, 0x78,
        0x00, 0x04,
        0xC0, 0xA8,
        0x01, 0x01,
    };

    var slices: [16][]const u8 = undefined;
    const data_rr = try ResourceRecord.decodeResourceRecord(&wire, &slices);
    const rr = data_rr.value;

    try testing.expectEqual(@as(usize, 4), rr.name.len);
    try testing.expectEqualStrings("tanuko", rr.name[0]);
    try testing.expectEqualStrings("_chat", rr.name[1]);
    try testing.expectEqualStrings("_tcp", rr.name[2]);
    try testing.expectEqualStrings("local", rr.name[3]);
    try testing.expectEqual(@as(u16, 1), rr.rtype);
    try testing.expectEqual(@as(u16, 1), rr.rclass);
    try testing.expectEqual(@as(u32, 0x12345678), rr.ttl);
    try testing.expectEqualSlices(u8, &sample_rdata, rr.rdata);
    try testing.expectEqual(@as(usize, wire.len), data_rr.consumed);
}

test "ResourceRecord: round-trip" {
    const original = ResourceRecord{
        .name = &sample_labels,
        .rtype = 1,
        .rclass = 1,
        .ttl = 0x12345678,
        .rdata = &sample_rdata,
    };

    var buf: [256]u8 = undefined;
    const written = try original.encodeResourceRecord(&buf);

    var slices: [16][]const u8 = undefined;
    const data_rr = try ResourceRecord.decodeResourceRecord(buf[0..written], &slices);
    const decoded = data_rr.value;

    try testing.expectEqual(original.name.len, decoded.name.len);
    for (original.name, decoded.name) |a, b| {
        try testing.expectEqualStrings(a, b);
    }
    try testing.expectEqual(original.rtype, decoded.rtype);
    try testing.expectEqual(original.rclass, decoded.rclass);
    try testing.expectEqual(original.ttl, decoded.ttl);
    try testing.expectEqualSlices(u8, original.rdata, decoded.rdata);
    try testing.expectEqual(written, data_rr.consumed);
}

// Message tests
test "Message: encode regenerates counts from arrays" {
    // Header has 99 sections in every counts, but it is not true, there's one question
    const msg = Message{
        .header = .{
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
            .qdcount = 99,
            .ancount = 99,
            .nscount = 99,
            .arcount = 99,
        },
        .questions = &[_]Question{
            .{ .qname = &sample_labels, .qtype = 1, .qclass = 1 },
        },
        .answers = &[_]ResourceRecord{},
        .authorities = &[_]ResourceRecord{},
        .additionals = &[_]ResourceRecord{},
    };

    var buf: [256]u8 = undefined;
    const written = try msg.encodeMessage(&buf);

    // Header(12) + 1 Question(29) = 41
    try testing.expectEqual(@as(usize, 41), written);

    // id should be 0
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00 }, buf[0..2]);
    // flags should be 0 (all bits in 0)
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00 }, buf[2..4]);
    // qdcount should be 1, not 99
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01 }, buf[4..6]);
    // ancount/nscount/arcount should be 0, not 99
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00 }, buf[6..8]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00 }, buf[8..10]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00 }, buf[10..12]);
}

test "Message: decode — empty message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var wire: [12]u8 = @splat(0);

    const msg = try Message.decodeMessage(arena.allocator(), &wire);

    try testing.expectEqual(@as(u16, 0), msg.header.qdcount);
    try testing.expectEqual(@as(usize, 0), msg.questions.len);
    try testing.expectEqual(@as(usize, 0), msg.answers.len);
    try testing.expectEqual(@as(usize, 0), msg.authorities.len);
    try testing.expectEqual(@as(usize, 0), msg.additionals.len);
}

test "Message: decode — DoS counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Header has qdcount = 0xFFFF but the max size of wire is 12 bytes.
    var wire: [12]u8 = @splat(0);
    wire[4] = 0xFF;
    wire[5] = 0xFF;

    try testing.expectError(error.Truncated, Message.decodeMessage(arena.allocator(), &wire));
}

test "Message: decode — trailing bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var wire: [15]u8 = @splat(0);

    try testing.expectError(error.TrailingBytes, Message.decodeMessage(arena.allocator(), &wire));
}

test "Message: encode — NoSpace" {
    const msg = Message{
        .header = .{
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
        },
        .questions = &[_]Question{},
        .answers = &[_]ResourceRecord{},
        .authorities = &[_]ResourceRecord{},
        .additionals = &[_]ResourceRecord{},
    };

    var buf: [11]u8 = undefined;
    try testing.expectError(error.NoSpace, msg.encodeMessage(&buf));
}

test "Message: round-trip — minimal query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const original = Message{
        .header = .{
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
        },
        .questions = &[_]Question{
            .{ .qname = &sample_labels, .qtype = 1, .qclass = 1 },
        },
        .answers = &[_]ResourceRecord{},
        .authorities = &[_]ResourceRecord{},
        .additionals = &[_]ResourceRecord{},
    };

    var buf: [256]u8 = undefined;
    const written = try original.encodeMessage(&buf);

    const decoded = try Message.decodeMessage(arena.allocator(), buf[0..written]);

    try testing.expectEqual(original.header.id, decoded.header.id);
    try testing.expectEqual(@as(u16, 1), decoded.header.qdcount);
    try testing.expectEqual(@as(usize, 1), decoded.questions.len);

    const q = decoded.questions[0];
    try testing.expectEqual(@as(usize, 4), q.qname.len);
    try testing.expectEqualStrings("tanuko", q.qname[0]);
    try testing.expectEqualStrings("_chat", q.qname[1]);
    try testing.expectEqualStrings("_tcp", q.qname[2]);
    try testing.expectEqualStrings("local", q.qname[3]);
    try testing.expectEqual(@as(u16, 1), q.qtype);
    try testing.expectEqual(@as(u16, 1), q.qclass);

    try testing.expectEqual(@as(usize, 0), decoded.answers.len);
    try testing.expectEqual(@as(usize, 0), decoded.authorities.len);
    try testing.expectEqual(@as(usize, 0), decoded.additionals.len);
}

test "Message: round-trip — response with one answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const original = Message{
        .header = .{
            .id = 0,
            .qr = 1,
            .opcode = 0,
            .aa = 1,
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
        },
        .questions = &[_]Question{},
        .answers = &[_]ResourceRecord{
            .{
                .name = &sample_labels,
                .rtype = 1,
                .rclass = 1,
                .ttl = 120,
                .rdata = &sample_rdata,
            },
        },
        .authorities = &[_]ResourceRecord{},
        .additionals = &[_]ResourceRecord{},
    };

    var buf: [256]u8 = undefined;
    const written = try original.encodeMessage(&buf);

    const decoded = try Message.decodeMessage(arena.allocator(), buf[0..written]);

    // Header flags
    try testing.expectEqual(@as(u1, 1), decoded.header.qr);
    try testing.expectEqual(@as(u1, 1), decoded.header.aa);
    try testing.expectEqual(@as(u16, 1), decoded.header.ancount);

    try testing.expectEqual(@as(usize, 0), decoded.questions.len);
    try testing.expectEqual(@as(usize, 1), decoded.answers.len);

    const rr = decoded.answers[0];
    try testing.expectEqual(@as(usize, 4), rr.name.len);
    try testing.expectEqualStrings("tanuko", rr.name[0]);
    try testing.expectEqualStrings("_chat", rr.name[1]);
    try testing.expectEqualStrings("_tcp", rr.name[2]);
    try testing.expectEqualStrings("local", rr.name[3]);
    try testing.expectEqual(@as(u16, 1), rr.rtype);
    try testing.expectEqual(@as(u16, 1), rr.rclass);
    try testing.expectEqual(@as(u32, 120), rr.ttl);
    try testing.expectEqualSlices(u8, &sample_rdata, rr.rdata);
}

test "Message: round-trip — mixed sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rdata_ptr = [_]u8{ 0xC0, 0xA8, 0x01, 0x01 }; // 192.168.1.1
    const rdata_srv = [_]u8{ 0, 0, 0, 0, 0x1F, 0x90 }; // priority=0, weight=0, port=8080

    const original = Message{
        .header = .{
            .id = 0,
            .qr = 1,
            .opcode = 0,
            .aa = 1,
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
        },
        .questions = &[_]Question{
            .{ .qname = &sample_labels, .qtype = 12, .qclass = 1 },
        },
        .answers = &[_]ResourceRecord{
            .{
                .name = &sample_labels,
                .rtype = 12, // PTR
                .rclass = 1,
                .ttl = 4500,
                .rdata = &sample_name_wire, // a PTR name (raw wire)
            },
        },
        .authorities = &[_]ResourceRecord{
            .{
                .name = &sample_labels,
                .rtype = 1, // A
                .rclass = 1,
                .ttl = 120,
                .rdata = &rdata_ptr,
            },
        },
        .additionals = &[_]ResourceRecord{
            .{
                .name = &sample_labels,
                .rtype = 33, // SRV
                .rclass = 1,
                .ttl = 120,
                .rdata = &rdata_srv,
            },
        },
    };

    var buf: [512]u8 = undefined;
    const written = try original.encodeMessage(&buf);

    const decoded = try Message.decodeMessage(arena.allocator(), buf[0..written]);

    // Counts
    try testing.expectEqual(@as(u16, 1), decoded.header.qdcount);
    try testing.expectEqual(@as(u16, 1), decoded.header.ancount);
    try testing.expectEqual(@as(u16, 1), decoded.header.nscount);
    try testing.expectEqual(@as(u16, 1), decoded.header.arcount);

    // Questions
    try testing.expectEqual(@as(usize, 1), decoded.questions.len);
    try testing.expectEqual(@as(u16, 12), decoded.questions[0].qtype);

    // Answers
    try testing.expectEqual(@as(usize, 1), decoded.answers.len);
    try testing.expectEqual(@as(u16, 12), decoded.answers[0].rtype);
    try testing.expectEqual(@as(u32, 4500), decoded.answers[0].ttl);
    try testing.expectEqualSlices(u8, &sample_name_wire, decoded.answers[0].rdata);

    // Authorities
    try testing.expectEqual(@as(usize, 1), decoded.authorities.len);
    try testing.expectEqual(@as(u16, 1), decoded.authorities[0].rtype);
    try testing.expectEqualSlices(u8, &rdata_ptr, decoded.authorities[0].rdata);

    // Additionals
    try testing.expectEqual(@as(usize, 1), decoded.additionals.len);
    try testing.expectEqual(@as(u16, 33), decoded.additionals[0].rtype);
    try testing.expectEqualSlices(u8, &rdata_srv, decoded.additionals[0].rdata);
}

test "Message: decode — DoS rejected without allocation" {
    // 64-byte buffer: enough for ONE Question (~11 bytes allocated),
    // not enough for 65,535 Questions (~1.5 MB).
    var fba_buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);

    // Header has qdcount = 0xFFFF but the max size of wire is 12 bytes.
    var wire: [12]u8 = @splat(0);
    wire[4] = 0xFF;
    wire[5] = 0xFF;

    // It should fail with “Truncated” (the min_bytes check), NOT with OutOfMemory.
    // Which is what would happen if it allocated first.
    try testing.expectError(error.Truncated, Message.decodeMessage(fba.allocator(), &wire));
}
