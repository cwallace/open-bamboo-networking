#include "rtcp_packet.hpp"

#include <cstdint>
#include <cstdio>

namespace {

int fail_count = 0;

#define CHECK(cond)                                                     \
    do {                                                                \
        if (!(cond)) {                                                  \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, \
                         #cond);                                        \
            ++fail_count;                                               \
        }                                                               \
    } while (0)

void test_interleaved_receiver_report()
{
    const auto packet =
        obn::rtsp::make_interleaved_rtcp_receiver_report(0x12345678u);
    const obn::rtsp::InterleavedRtcpReceiverReport expected{
        '$', 1, 0, 24,
        0x80, 201, 0, 1, 0x12, 0x34, 0x56, 0x78,
        0x81, 202, 0, 3, 0x12, 0x34, 0x56, 0x78,
        1, 3, 'o', 'b', 'n', 0, 0, 0,
    };
    CHECK(packet == expected);

    const auto other =
        obn::rtsp::make_interleaved_rtcp_receiver_report(0xaabbccddu);
    CHECK(other[8] == 0xaa && other[9] == 0xbb &&
          other[10] == 0xcc && other[11] == 0xdd);
    CHECK(other[16] == 0xaa && other[17] == 0xbb &&
          other[18] == 0xcc && other[19] == 0xdd);
    CHECK(other[0] == '$' && other[1] == 1 && other[3] == 24);
}

} // namespace

int main()
{
    test_interleaved_receiver_report();
    if (fail_count) {
        std::fprintf(stderr, "%d check(s) failed\n", fail_count);
        return 1;
    }
    std::puts("rtcp_packet_test: all checks passed");
    return 0;
}
