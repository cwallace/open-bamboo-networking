// H.264 Annex-B access-unit parsing for the macOS BambuPlayer adapter.
//
// libBambuSource's RTSP passthrough emits one access unit at a time with
// Annex-B start codes. CoreMedia expects AVC samples whose NAL units are
// prefixed by a four-byte, big-endian payload length. This helper performs
// only that framing conversion; it does not decode or otherwise transform
// the video stream.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace obn::h264 {

constexpr std::size_t kMaxAccessUnitSize = 16u * 1024u * 1024u;

struct AccessUnit {
    // Length-prefixed AVC sample data. SPS/PPS NAL units are deliberately
    // omitted: CoreMedia receives them through CMVideoFormatDescription.
    std::vector<std::uint8_t> avcc;
    std::vector<std::uint8_t> sps;
    std::vector<std::uint8_t> pps;
    bool keyframe = false;
    std::size_t nal_count = 0;
};

enum class ParseResult {
    Ok,
    Empty,
    TooLarge,
    MissingStartCode,
    EmptyNalu,
};

// Parse one complete Annex-B access unit and convert its non-parameter-set
// NAL units to AVC length-prefix framing. `out` is reset on every call.
ParseResult annexb_to_avcc(const std::uint8_t* data,
                           std::size_t size,
                           AccessUnit* out);

const char* parse_result_string(ParseResult result);

} // namespace obn::h264
