#include "rtcp_packet.hpp"

namespace obn::rtsp {

InterleavedRtcpReceiverReport
make_interleaved_rtcp_receiver_report(std::uint32_t receiver_ssrc)
{
    InterleavedRtcpReceiverReport packet{
        '$', 1, 0, 24,
        0x80, 201, 0, 1, 0, 0, 0, 0,
        0x81, 202, 0, 3, 0, 0, 0, 0,
        1, 3, 'o', 'b', 'n', 0, 0, 0,
    };
    auto put_ssrc = [&](std::size_t offset) {
        packet[offset] = static_cast<std::uint8_t>(receiver_ssrc >> 24);
        packet[offset + 1] = static_cast<std::uint8_t>(receiver_ssrc >> 16);
        packet[offset + 2] = static_cast<std::uint8_t>(receiver_ssrc >> 8);
        packet[offset + 3] = static_cast<std::uint8_t>(receiver_ssrc);
    };
    put_ssrc(8);
    put_ssrc(16);
    return packet;
}

} // namespace obn::rtsp
