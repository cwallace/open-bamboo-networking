#include "h264_sample_adapter.hpp"

#include <algorithm>

namespace obn::h264 {
namespace {

struct StartCode {
    std::size_t offset = 0;
    std::size_t size = 0;
};

bool find_start_code(const std::uint8_t* data,
                     std::size_t size,
                     std::size_t from,
                     StartCode* out)
{
    if (!data || !out || from >= size) return false;

    for (std::size_t i = from; i + 2 < size; ++i) {
        if (data[i] != 0 || data[i + 1] != 0) continue;
        if (data[i + 2] == 1) {
            out->offset = i;
            out->size = 3;
            return true;
        }
        if (i + 3 < size && data[i + 2] == 0 && data[i + 3] == 1) {
            out->offset = i;
            out->size = 4;
            return true;
        }
    }
    return false;
}

void append_u32_be(std::vector<std::uint8_t>* out, std::uint32_t value)
{
    out->push_back(static_cast<std::uint8_t>((value >> 24) & 0xff));
    out->push_back(static_cast<std::uint8_t>((value >> 16) & 0xff));
    out->push_back(static_cast<std::uint8_t>((value >> 8) & 0xff));
    out->push_back(static_cast<std::uint8_t>(value & 0xff));
}

} // namespace

ParseResult annexb_to_avcc(const std::uint8_t* data,
                           std::size_t size,
                           AccessUnit* out)
{
    if (!out) return ParseResult::Empty;
    *out = {};
    if (!data || size == 0) return ParseResult::Empty;
    if (size > kMaxAccessUnitSize) return ParseResult::TooLarge;

    StartCode current;
    if (!find_start_code(data, size, 0, &current)) {
        return ParseResult::MissingStartCode;
    }

    // Annex-B permits leading zero bytes before the first start code but no
    // other data. Rejecting a non-zero prefix catches accidental AVCC input.
    if (std::any_of(data, data + current.offset,
                    [](std::uint8_t byte) { return byte != 0; })) {
        return ParseResult::MissingStartCode;
    }

    while (true) {
        const std::size_t nalu_begin = current.offset + current.size;
        StartCode next;
        const bool has_next = find_start_code(data, size, nalu_begin, &next);
        std::size_t nalu_end = has_next ? next.offset : size;

        // Annex-B trailing_zero_8bits may appear before the next start code
        // or at the end of the byte stream; they are not part of the NAL.
        while (nalu_end > nalu_begin && data[nalu_end - 1] == 0) {
            --nalu_end;
        }
        if (nalu_begin >= nalu_end) return ParseResult::EmptyNalu;

        const std::size_t nalu_size = nalu_end - nalu_begin;
        ++out->nal_count;
        const std::uint8_t nal_type = data[nalu_begin] & 0x1f;
        if (nal_type == 7) {
            out->sps.assign(data + nalu_begin, data + nalu_end);
        } else if (nal_type == 8) {
            out->pps.assign(data + nalu_begin, data + nalu_end);
        } else {
            if (nal_type == 5) out->keyframe = true;
            append_u32_be(&out->avcc, static_cast<std::uint32_t>(nalu_size));
            out->avcc.insert(out->avcc.end(), data + nalu_begin,
                             data + nalu_end);
        }

        if (!has_next) break;
        current = next;
    }

    return ParseResult::Ok;
}

const char* parse_result_string(ParseResult result)
{
    switch (result) {
    case ParseResult::Ok:               return "ok";
    case ParseResult::Empty:            return "empty input";
    case ParseResult::TooLarge:         return "access unit too large";
    case ParseResult::MissingStartCode: return "missing Annex-B start code";
    case ParseResult::EmptyNalu:        return "empty NAL unit";
    }
    return "unknown parse error";
}

} // namespace obn::h264
