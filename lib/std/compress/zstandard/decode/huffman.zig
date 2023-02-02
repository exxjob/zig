const std = @import("std");

const types = @import("../types.zig");
const LiteralsSection = types.compressed_block.LiteralsSection;
const Table = types.compressed_block.Table;

const readers = @import("../readers.zig");

const decodeFseTable = @import("fse.zig").decodeFseTable;

pub const Error = error{
    MalformedHuffmanTree,
    MalformedFseTable,
    MalformedAccuracyLog,
    EndOfStream,
};

fn decodeFseHuffmanTree(source: anytype, compressed_size: usize, buffer: []u8, weights: *[256]u4) !usize {
    var stream = std.io.limitedReader(source, compressed_size);
    var bit_reader = readers.bitReader(stream.reader());

    var entries: [1 << 6]Table.Fse = undefined;
    const table_size = decodeFseTable(&bit_reader, 256, 6, &entries) catch |err| switch (err) {
        error.MalformedAccuracyLog, error.MalformedFseTable => |e| return e,
        error.EndOfStream => return error.MalformedFseTable,
    };
    const accuracy_log = std.math.log2_int_ceil(usize, table_size);

    const amount = try stream.reader().readAll(buffer);
    var huff_bits: readers.ReverseBitReader = undefined;
    huff_bits.init(buffer[0..amount]) catch return error.MalformedHuffmanTree;

    return assignWeights(&huff_bits, accuracy_log, &entries, weights);
}

fn decodeFseHuffmanTreeSlice(src: []const u8, compressed_size: usize, weights: *[256]u4) !usize {
    if (src.len < compressed_size) return error.MalformedHuffmanTree;
    var stream = std.io.fixedBufferStream(src[0..compressed_size]);
    var counting_reader = std.io.countingReader(stream.reader());
    var bit_reader = readers.bitReader(counting_reader.reader());

    var entries: [1 << 6]Table.Fse = undefined;
    const table_size = decodeFseTable(&bit_reader, 256, 6, &entries) catch |err| switch (err) {
        error.MalformedAccuracyLog, error.MalformedFseTable => |e| return e,
        error.EndOfStream => return error.MalformedFseTable,
    };
    const accuracy_log = std.math.log2_int_ceil(usize, table_size);

    const start_index = std.math.cast(usize, counting_reader.bytes_read) orelse return error.MalformedHuffmanTree;
    var huff_data = src[start_index..compressed_size];
    var huff_bits: readers.ReverseBitReader = undefined;
    huff_bits.init(huff_data) catch return error.MalformedHuffmanTree;

    return assignWeights(&huff_bits, accuracy_log, &entries, weights);
}

fn assignWeights(huff_bits: *readers.ReverseBitReader, accuracy_log: usize, entries: *[1 << 6]Table.Fse, weights: *[256]u4) !usize {
    var i: usize = 0;
    var even_state: u32 = huff_bits.readBitsNoEof(u32, accuracy_log) catch return error.MalformedHuffmanTree;
    var odd_state: u32 = huff_bits.readBitsNoEof(u32, accuracy_log) catch return error.MalformedHuffmanTree;

    while (i < 255) {
        const even_data = entries[even_state];
        var read_bits: usize = 0;
        const even_bits = huff_bits.readBits(u32, even_data.bits, &read_bits) catch unreachable;
        weights[i] = std.math.cast(u4, even_data.symbol) orelse return error.MalformedHuffmanTree;
        i += 1;
        if (read_bits < even_data.bits) {
            weights[i] = std.math.cast(u4, entries[odd_state].symbol) orelse return error.MalformedHuffmanTree;
            i += 1;
            break;
        }
        even_state = even_data.baseline + even_bits;

        read_bits = 0;
        const odd_data = entries[odd_state];
        const odd_bits = huff_bits.readBits(u32, odd_data.bits, &read_bits) catch unreachable;
        weights[i] = std.math.cast(u4, odd_data.symbol) orelse return error.MalformedHuffmanTree;
        i += 1;
        if (read_bits < odd_data.bits) {
            if (i == 256) return error.MalformedHuffmanTree;
            weights[i] = std.math.cast(u4, entries[even_state].symbol) orelse return error.MalformedHuffmanTree;
            i += 1;
            break;
        }
        odd_state = odd_data.baseline + odd_bits;
    } else return error.MalformedHuffmanTree;

    return i + 1; // stream contains all but the last symbol
}

fn decodeDirectHuffmanTree(source: anytype, encoded_symbol_count: usize, weights: *[256]u4) !usize {
    const weights_byte_count = (encoded_symbol_count + 1) / 2;
    var i: usize = 0;
    while (i < weights_byte_count) : (i += 1) {
        const byte = try source.readByte();
        weights[2 * i] = @intCast(u4, byte >> 4);
        weights[2 * i + 1] = @intCast(u4, byte & 0xF);
    }
    return encoded_symbol_count + 1;
}

fn assignSymbols(weight_sorted_prefixed_symbols: []LiteralsSection.HuffmanTree.PrefixedSymbol, weights: [256]u4) usize {
    for (weight_sorted_prefixed_symbols) |_, i| {
        weight_sorted_prefixed_symbols[i] = .{
            .symbol = @intCast(u8, i),
            .weight = undefined,
            .prefix = undefined,
        };
    }

    std.sort.sort(
        LiteralsSection.HuffmanTree.PrefixedSymbol,
        weight_sorted_prefixed_symbols,
        weights,
        lessThanByWeight,
    );

    var prefix: u16 = 0;
    var prefixed_symbol_count: usize = 0;
    var sorted_index: usize = 0;
    const symbol_count = weight_sorted_prefixed_symbols.len;
    while (sorted_index < symbol_count) {
        var symbol = weight_sorted_prefixed_symbols[sorted_index].symbol;
        const weight = weights[symbol];
        if (weight == 0) {
            sorted_index += 1;
            continue;
        }

        while (sorted_index < symbol_count) : ({
            sorted_index += 1;
            prefixed_symbol_count += 1;
            prefix += 1;
        }) {
            symbol = weight_sorted_prefixed_symbols[sorted_index].symbol;
            if (weights[symbol] != weight) {
                prefix = ((prefix - 1) >> (weights[symbol] - weight)) + 1;
                break;
            }
            weight_sorted_prefixed_symbols[prefixed_symbol_count].symbol = symbol;
            weight_sorted_prefixed_symbols[prefixed_symbol_count].prefix = prefix;
            weight_sorted_prefixed_symbols[prefixed_symbol_count].weight = weight;
        }
    }
    return prefixed_symbol_count;
}

fn buildHuffmanTree(weights: *[256]u4, symbol_count: usize) LiteralsSection.HuffmanTree {
    var weight_power_sum: u16 = 0;
    for (weights[0 .. symbol_count - 1]) |value| {
        if (value > 0) {
            weight_power_sum += @as(u16, 1) << (value - 1);
        }
    }

    // advance to next power of two (even if weight_power_sum is a power of 2)
    const max_number_of_bits = std.math.log2_int(u16, weight_power_sum) + 1;
    const next_power_of_two = @as(u16, 1) << max_number_of_bits;
    weights[symbol_count - 1] = std.math.log2_int(u16, next_power_of_two - weight_power_sum) + 1;

    var weight_sorted_prefixed_symbols: [256]LiteralsSection.HuffmanTree.PrefixedSymbol = undefined;
    const prefixed_symbol_count = assignSymbols(weight_sorted_prefixed_symbols[0..symbol_count], weights.*);
    const tree = LiteralsSection.HuffmanTree{
        .max_bit_count = max_number_of_bits,
        .symbol_count_minus_one = @intCast(u8, prefixed_symbol_count - 1),
        .nodes = weight_sorted_prefixed_symbols,
    };
    return tree;
}

pub fn decodeHuffmanTree(source: anytype, buffer: []u8) !LiteralsSection.HuffmanTree {
    const header = try source.readByte();
    var weights: [256]u4 = undefined;
    const symbol_count = if (header < 128)
        // FSE compressed weights
        try decodeFseHuffmanTree(source, header, buffer, &weights)
    else
        try decodeDirectHuffmanTree(source, header - 127, &weights);

    return buildHuffmanTree(&weights, symbol_count);
}

pub fn decodeHuffmanTreeSlice(src: []const u8, consumed_count: *usize) Error!LiteralsSection.HuffmanTree {
    if (src.len == 0) return error.MalformedHuffmanTree;
    const header = src[0];
    var bytes_read: usize = 1;
    var weights: [256]u4 = undefined;
    const symbol_count = if (header < 128) count: {
        // FSE compressed weights
        bytes_read += header;
        break :count try decodeFseHuffmanTreeSlice(src[1..], header, &weights);
    } else count: {
        var fbs = std.io.fixedBufferStream(src[1..]);
        defer bytes_read += fbs.pos;
        break :count try decodeDirectHuffmanTree(fbs.reader(), header - 127, &weights);
    };

    consumed_count.* += bytes_read;
    return buildHuffmanTree(&weights, symbol_count);
}

fn lessThanByWeight(
    weights: [256]u4,
    lhs: LiteralsSection.HuffmanTree.PrefixedSymbol,
    rhs: LiteralsSection.HuffmanTree.PrefixedSymbol,
) bool {
    // NOTE: this function relies on the use of a stable sorting algorithm,
    //       otherwise a special case of if (weights[lhs] == weights[rhs]) return lhs < rhs;
    //       should be added
    return weights[lhs.symbol] < weights[rhs.symbol];
}
