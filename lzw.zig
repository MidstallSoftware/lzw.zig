const std = @import("std");
const Allocator = std.mem.Allocator;

/// Decoder ported from zigimg's lzw decoder with some minor changes.
pub fn Decoder(comptime Endian: std.builtin.Endian) type {
    return struct {
        const Self = @This();
        const MaxCodeSize = 12;

        codeSize: u8 = 0,
        clearCode: u13 = 0,
        initCodeSize: u8 = 0,
        endInfoCode: u13 = 0,
        nextCode: u13 = 0,
        prevCode: ?u13 = null,
        dict: std.AutoArrayHashMap(u13, []const u8),
        remData: ?u13 = null,
        remBits: u4 = 0,

        pub fn init(alloc: Allocator, initCodeSize: u8) !Self {
            var self = Self{
                .codeSize = initCodeSize,
                .dict = std.AutoArrayHashMap(u13, []const u8).init(alloc),
                .initCodeSize = initCodeSize,
                .clearCode = @as(u13, 1) << @intCast(initCodeSize),
                .endInfoCode = (@as(u13, 1) << @intCast(initCodeSize)) + 1,
                .nextCode = (@as(u13, 1) << @intCast(initCodeSize)) + 2,
            };
            errdefer self.deinit();

            try self.reset();
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.dict.values()) |v| self.dict.allocator.free(v);
            self.dict.deinit();
        }

        pub fn reset(self: *Self) !void {
            for (self.dict.values()) |v| self.dict.allocator.free(v);
            self.dict.clearRetainingCapacity();

            self.codeSize = self.initCodeSize;
            self.nextCode = (@as(u13, 1) << @intCast(self.initCodeSize)) + 2;

            const rootSize = @as(usize, 1) << @intCast(self.codeSize);
            var i: u13 = 0;
            while (i < rootSize) : (i += 1) {
                var data = try self.dict.allocator.alloc(u8, 1);
                data[0] = @as(u8, @truncate(i));
                try self.dict.put(i, data);
            }
        }

        pub fn decode(self: *Self, reader: anytype) !std.ArrayList(u8) {
            var bReader = std.io.bitReader(Endian, reader);
            var readBits = self.codeSize + 1;

            var readSize: usize = 0;
            var readCode: u13 = 0;

            var list = std.ArrayList(u8).init(self.dict.allocator);
            errdefer list.deinit();

            if (self.remData) |remData| {
                const restOfData = try bReader.readBits(u13, self.remBits, &readSize);
                if (readSize > 0) {
                    readCode = switch (Endian) {
                        .little => remData | (restOfData << @as(u4, @intCast(readBits - self.remBits))),
                        .big => (remData << self.remBits) | restOfData,
                    };
                }

                self.remData = null;
            } else {
                readCode = try bReader.readBits(u13, readBits, &readSize);
            }

            while (readSize > 0) {
                if (self.dict.get(readCode)) |value| {
                    try list.appendSlice(value);

                    if (self.prevCode) |prevCode| {
                        if (self.dict.get(prevCode)) |prevValue| {
                            var newVal = try self.dict.allocator.alloc(u8, prevValue.len + 1);
                            errdefer self.dict.allocator.free(newVal);

                            std.mem.copyForwards(u8, newVal, prevValue);
                            newVal[prevValue.len] = value[0];

                            try self.dict.put(self.nextCode, newVal);

                            self.nextCode += 1;

                            const maxCode = @as(u13, 1) << @intCast(self.codeSize + 1);
                            if (self.nextCode == maxCode and (self.codeSize + 1) < MaxCodeSize) {
                                self.codeSize += 1;
                                readBits += 1;
                            }
                        }
                    }
                } else {
                    if (readCode == self.clearCode) {
                        try self.reset();

                        readBits = self.codeSize + 1;
                        self.prevCode = readCode;
                    } else if (readCode == self.endInfoCode) {
                        return list;
                    } else {
                        if (self.prevCode) |prevCode| {
                            if (self.dict.get(prevCode)) |prevValue| {
                                var newVal = try self.dict.allocator.alloc(u8, prevValue.len + 1);
                                errdefer self.dict.allocator.free(newVal);

                                std.mem.copyForwards(u8, newVal, prevValue);
                                newVal[prevValue.len] = prevValue[0];

                                try self.dict.put(self.nextCode, newVal);

                                try list.appendSlice(newVal);
                                self.nextCode += 1;

                                const maxCode = @as(u13, 1) << @intCast(self.codeSize + 1);
                                if (self.nextCode == maxCode and (self.codeSize + 1) < MaxCodeSize) {
                                    self.codeSize += 1;
                                    readBits += 1;
                                }
                            }
                        }
                    }
                }

                self.prevCode = readCode;
                readCode = try bReader.readBits(u13, readBits, &readSize);
                if (readSize != readBits) {
                    self.remData = readCode;
                    self.remBits = @intCast(readBits - readSize);
                    return list;
                }
            }

            return list;
        }
    };
}

pub const LittleDecoder = Decoder(.little);
pub const BigDecoder = Decoder(.big);

test "Simple decode in LE" {
    const inData = [_]u8{ 0x4c, 0x01 };
    var inStream = std.io.fixedBufferStream(&inData);

    var lzw = try LittleDecoder.init(std.testing.allocator, 2);
    defer lzw.deinit();

    const result = try lzw.decode(inStream.reader());
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqual(@as(u8, 1), result.items[0]);
}
