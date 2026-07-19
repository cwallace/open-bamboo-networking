// Minimal RTCP compound packet used to keep Bambu's live555 camera server
// forwarding RTP, including its RTSP interleaved channel framing.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace obn::rtsp {

using InterleavedRtcpReceiverReport = std::array<std::uint8_t, 28>;

// RFC 3550 compound packet: an empty Receiver Report followed by one SDES
// CNAME chunk containing the stable client name "obn".
InterleavedRtcpReceiverReport
make_interleaved_rtcp_receiver_report(std::uint32_t receiver_ssrc);

} // namespace obn::rtsp
