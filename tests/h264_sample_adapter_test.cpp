#include "h264_sample_adapter.hpp"

#include <cstdint>
#include <cstdio>
#include <vector>

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

using obn::h264::AccessUnit;
using obn::h264::ParseResult;
using obn::h264::annexb_to_avcc;

void test_parameter_sets_and_video_nalus()
{
    const std::vector<std::uint8_t> input{
        0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1f,
        0, 0, 1,    0x68, 0xee, 0x3c, 0x80,
        0, 0, 0, 1, 0x65, 0x88, 0x84,
        0, 0, 1,    0x41, 0x9a,
    };
    AccessUnit out;
    CHECK(annexb_to_avcc(input.data(), input.size(), &out) ==
          ParseResult::Ok);
    CHECK(out.nal_count == 4);
    CHECK(out.keyframe);
    CHECK(out.sps == std::vector<std::uint8_t>({0x67, 0x64, 0x00, 0x1f}));
    CHECK(out.pps == std::vector<std::uint8_t>({0x68, 0xee, 0x3c, 0x80}));
    CHECK(out.avcc == std::vector<std::uint8_t>({
        0, 0, 0, 3, 0x65, 0x88, 0x84,
        0, 0, 0, 2, 0x41, 0x9a,
    }));
}

void test_leading_and_trailing_zero_bytes()
{
    const std::vector<std::uint8_t> input{
        0, 0, 0, 0, 1, 0x41, 0xaa, 0, 0,
    };
    AccessUnit out;
    CHECK(annexb_to_avcc(input.data(), input.size(), &out) ==
          ParseResult::Ok);
    CHECK(out.nal_count == 1);
    CHECK(!out.keyframe);
    CHECK(out.avcc == std::vector<std::uint8_t>({0, 0, 0, 2, 0x41, 0xaa}));
}

void test_parameter_set_only_access_unit()
{
    const std::vector<std::uint8_t> input{
        0, 0, 1, 0x67, 0x42, 0x01,
        0, 0, 1, 0x68, 0xce, 0x02,
    };
    AccessUnit out;
    CHECK(annexb_to_avcc(input.data(), input.size(), &out) ==
          ParseResult::Ok);
    CHECK(out.nal_count == 2);
    CHECK(!out.sps.empty());
    CHECK(!out.pps.empty());
    CHECK(out.avcc.empty());
}

void test_invalid_inputs_reset_output()
{
    AccessUnit out;
    out.avcc = {1, 2, 3};
    out.sps = {4};
    out.pps = {5};
    out.keyframe = true;
    out.nal_count = 9;

    CHECK(annexb_to_avcc(nullptr, 0, &out) == ParseResult::Empty);
    CHECK(out.avcc.empty() && out.sps.empty() && out.pps.empty());
    CHECK(!out.keyframe && out.nal_count == 0);
    CHECK(annexb_to_avcc(nullptr, 0, nullptr) == ParseResult::Empty);

    const std::vector<std::uint8_t> no_start_code{0x65, 0x88, 0x84};
    CHECK(annexb_to_avcc(no_start_code.data(), no_start_code.size(), &out) ==
          ParseResult::MissingStartCode);

    const std::vector<std::uint8_t> nonzero_prefix{
        0xff, 0, 0, 1, 0x65,
    };
    CHECK(annexb_to_avcc(nonzero_prefix.data(), nonzero_prefix.size(), &out) ==
          ParseResult::MissingStartCode);

    const std::vector<std::uint8_t> empty_nalu{
        0, 0, 1, 0, 0, 1, 0x65,
    };
    CHECK(annexb_to_avcc(empty_nalu.data(), empty_nalu.size(), &out) ==
          ParseResult::EmptyNalu);

    const std::uint8_t byte = 0;
    CHECK(annexb_to_avcc(&byte, obn::h264::kMaxAccessUnitSize + 1, &out) ==
          ParseResult::TooLarge);
}

} // namespace

int main()
{
    test_parameter_sets_and_video_nalus();
    test_leading_and_trailing_zero_bytes();
    test_parameter_set_only_access_unit();
    test_invalid_inputs_reset_output();

    if (fail_count) {
        std::fprintf(stderr, "%d check(s) failed\n", fail_count);
        return 1;
    }
    std::puts("h264_sample_adapter_test: all checks passed");
    return 0;
}
