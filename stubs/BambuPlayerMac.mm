// macOS presentation adapter expected by OrcaSlicer/Bambu Studio.
//
// The slicer's wxMediaCtrl2.mm resolves OBJC_CLASS_$_BambuPlayer from
// libBambuSource.dylib. Transport remains in the existing Bambu_* C ABI;
// this class only converts Annex-B samples to CoreMedia buffers and presents
// them with AVSampleBufferDisplayLayer.

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>

#include "bambu_source_abi.hpp"
#include "h264_sample_adapter.hpp"
#include "source_log.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using PlayerLogger = void (*)(const void* context, int level,
                              const char* message);

bool renderer_ready(AVSampleBufferDisplayLayer* layer)
{
    if (@available(macOS 14.0, *)) {
        return layer.sampleBufferRenderer.readyForMoreMediaData;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return layer.readyForMoreMediaData;
#pragma clang diagnostic pop
}

void renderer_enqueue(AVSampleBufferDisplayLayer* layer,
                      CMSampleBufferRef sample)
{
    if (@available(macOS 14.0, *)) {
        [layer.sampleBufferRenderer enqueueSampleBuffer:sample];
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [layer enqueueSampleBuffer:sample];
#pragma clang diagnostic pop
}

AVQueuedSampleBufferRenderingStatus
renderer_status(AVSampleBufferDisplayLayer* layer)
{
    if (@available(macOS 14.0, *)) {
        return layer.sampleBufferRenderer.status;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return layer.status;
#pragma clang diagnostic pop
}

NSError* renderer_error(AVSampleBufferDisplayLayer* layer)
{
    if (@available(macOS 14.0, *)) {
        return layer.sampleBufferRenderer.error;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return layer.error;
#pragma clang diagnostic pop
}

void renderer_flush(AVSampleBufferDisplayLayer* layer, bool remove_image)
{
    if (@available(macOS 14.0, *)) {
        [layer.sampleBufferRenderer
            flushWithRemovalOfDisplayedImage:remove_image
                           completionHandler:nil];
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (remove_image) [layer flushAndRemoveImage];
    else [layer flush];
#pragma clang diagnostic pop
}

AVSampleBufferRenderSynchronizer*
create_render_synchronizer(AVSampleBufferDisplayLayer* layer)
{
    AVSampleBufferRenderSynchronizer* synchronizer =
        [[AVSampleBufferRenderSynchronizer alloc] init];
    if (@available(macOS 14.0, *)) {
        [synchronizer addRenderer:layer.sampleBufferRenderer];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [synchronizer addRenderer:layer];
#pragma clang diagnostic pop
    }
    return synchronizer;
}

struct PendingAccessUnit {
    obn::h264::AccessUnit access_unit;
    std::uint64_t timestamp_100ns = 0;
    bool valid = false;
};

struct MacPlayerState {
    AVSampleBufferDisplayLayer* layer = nil; // owned by BambuPlayer
    Bambu_Tunnel tunnel = nullptr;
    std::thread worker;
    std::atomic<bool> stop_requested{false};
    std::atomic<bool> playing{false};
    std::mutex state_mutex;

    PlayerLogger player_logger = nullptr;
    const void* player_log_context = nullptr;

    CMVideoFormatDescriptionRef format = nullptr;
    std::vector<std::uint8_t> sps;
    std::vector<std::uint8_t> pps;
    PendingAccessUnit pending;
    int width = 0;
    int height = 0;
    int frame_rate = 30;
    std::uint64_t last_timestamp_100ns = 0;
    bool have_timestamp = false;

    ~MacPlayerState()
    {
        if (format) CFRelease(format);
    }

    void log(obn::source::LogLevel level, const std::string& message)
    {
        obn::source::log_at(level, nullptr, nullptr, "%s", message.c_str());
        PlayerLogger callback = nullptr;
        const void* context = nullptr;
        {
            std::lock_guard<std::mutex> lock(state_mutex);
            callback = player_logger;
            context = player_log_context;
        }
        if (callback) callback(context, static_cast<int>(level), message.c_str());
    }

    void fail(int code, const std::string& detail, bool notify_stopped)
    {
        const std::string message = "mac_player: " + detail + " [" +
                                    std::to_string(code) + "]";
        obn::source::log_at(obn::source::LL_ERROR, nullptr, nullptr,
                            "%s", message.c_str());
        PlayerLogger callback = nullptr;
        const void* context = nullptr;
        {
            std::lock_guard<std::mutex> lock(state_mutex);
            callback = player_logger;
            context = player_log_context;
        }
        if (callback) {
            // Orca parses a trailing [code] from level 1 messages, then uses
            // a negative level as the asynchronous stopped notification.
            callback(context, 1, message.c_str());
            if (notify_stopped) callback(context, -1, message.c_str());
        }
    }

    bool update_format(const obn::h264::AccessUnit& access_unit)
    {
        bool changed = false;
        if (!access_unit.sps.empty() && access_unit.sps != sps) {
            sps = access_unit.sps;
            changed = true;
        }
        if (!access_unit.pps.empty() && access_unit.pps != pps) {
            pps = access_unit.pps;
            changed = true;
        }
        if (sps.empty() || pps.empty()) return format != nullptr;
        if (format && !changed) return true;

        const std::uint8_t* parameter_sets[] = {sps.data(), pps.data()};
        const std::size_t parameter_set_sizes[] = {sps.size(), pps.size()};
        CMVideoFormatDescriptionRef replacement = nullptr;
        const OSStatus status =
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                kCFAllocatorDefault, 2, parameter_sets,
                parameter_set_sizes, 4, &replacement);
        if (status != noErr || !replacement) {
            fail(-21, "could not create H.264 format description (status=" +
                      std::to_string(status) + ")", false);
            return false;
        }

        if (format) CFRelease(format);
        format = replacement;
        const CMVideoDimensions dimensions =
            CMVideoFormatDescriptionGetDimensions(format);
        {
            std::lock_guard<std::mutex> lock(state_mutex);
            width = dimensions.width;
            height = dimensions.height;
        }
        log(obn::source::LL_INFO,
            "mac_player: H.264 format ready " + std::to_string(width) + "x" +
            std::to_string(height));
        return width > 0 && height > 0;
    }

    std::uint64_t monotonic_timestamp(std::uint64_t timestamp)
    {
        const std::uint64_t nominal_step =
            10'000'000u / static_cast<std::uint64_t>(frame_rate > 0 ?
                                                     frame_rate : 30);
        if (!have_timestamp) {
            have_timestamp = true;
            last_timestamp_100ns = timestamp;
            return timestamp;
        }
        if (timestamp <= last_timestamp_100ns) {
            timestamp = last_timestamp_100ns + nominal_step;
        }
        last_timestamp_100ns = timestamp;
        return timestamp;
    }

    CMSampleBufferRef make_sample(obn::h264::AccessUnit& access_unit,
                                  std::uint64_t timestamp_100ns)
    {
        if (!update_format(access_unit) || access_unit.avcc.empty()) {
            return nullptr;
        }

        CMBlockBufferRef block = nullptr;
        OSStatus status = CMBlockBufferCreateWithMemoryBlock(
            kCFAllocatorDefault, nullptr, access_unit.avcc.size(),
            kCFAllocatorDefault, nullptr, 0, access_unit.avcc.size(), 0,
            &block);
        if (status != kCMBlockBufferNoErr || !block) {
            fail(-22, "could not allocate CoreMedia block (status=" +
                      std::to_string(status) + ")", false);
            return nullptr;
        }
        status = CMBlockBufferReplaceDataBytes(
            access_unit.avcc.data(), block, 0, access_unit.avcc.size());
        if (status != kCMBlockBufferNoErr) {
            CFRelease(block);
            fail(-23, "could not copy H.264 sample (status=" +
                      std::to_string(status) + ")", false);
            return nullptr;
        }

        timestamp_100ns = monotonic_timestamp(timestamp_100ns);
        CMSampleTimingInfo timing{};
        timing.duration = CMTimeMake(1, frame_rate > 0 ? frame_rate : 30);
        timing.presentationTimeStamp = CMTimeMake(
            static_cast<std::int64_t>(timestamp_100ns), 10'000'000);
        timing.decodeTimeStamp = kCMTimeInvalid;
        const std::size_t sample_size = access_unit.avcc.size();
        CMSampleBufferRef sample = nullptr;
        status = CMSampleBufferCreateReady(
            kCFAllocatorDefault, block, format, 1, 1, &timing, 1,
            &sample_size, &sample);
        CFRelease(block);
        if (status != noErr || !sample) {
            fail(-24, "could not create video sample (status=" +
                      std::to_string(status) + ")", false);
            return nullptr;
        }

        CFArrayRef attachments =
            CMSampleBufferGetSampleAttachmentsArray(sample, true);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            auto* attachment = static_cast<CFMutableDictionaryRef>(
                const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
            // This is an interactive LAN live stream. Its timestamps describe
            // capture time, so samples are already a few milliseconds old by
            // the time CoreMedia sees them. Avoid deadline-based frame drops
            // and present each decoded frame as soon as it is available.
            CFDictionarySetValue(attachment,
                                 kCMSampleAttachmentKey_DisplayImmediately,
                                 kCFBooleanTrue);
            if (!access_unit.keyframe) {
                CFDictionarySetValue(attachment,
                                     kCMSampleAttachmentKey_NotSync,
                                     kCFBooleanTrue);
            }
        }
        return sample;
    }

    bool enqueue(obn::h264::AccessUnit access_unit,
                 std::uint64_t timestamp_100ns)
    {
        CMSampleBufferRef sample = make_sample(access_unit, timestamp_100ns);
        if (!sample) return false;

        while (!stop_requested.load(std::memory_order_acquire) &&
               !renderer_ready(layer)) {
            if (renderer_status(layer) ==
                AVQueuedSampleBufferRenderingStatusFailed) {
                NSString* description = renderer_error(layer).localizedDescription;
                CFRelease(sample);
                fail(-25, std::string("display layer failed while waiting: ") +
                          (description ? description.UTF8String : "unknown error"),
                     true);
                return false;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        if (stop_requested.load(std::memory_order_acquire)) {
            CFRelease(sample);
            return false;
        }

        renderer_enqueue(layer, sample);
        CFRelease(sample);
        if (renderer_status(layer) ==
            AVQueuedSampleBufferRenderingStatusFailed) {
            NSString* description = renderer_error(layer).localizedDescription;
            fail(-25, std::string("display layer failed: ") +
                      (description ? description.UTF8String : "unknown error"),
                 true);
            return false;
        }
        return true;
    }

    void run()
    {
        log(obn::source::LL_INFO, "mac_player: sample worker started");
        bool first_enqueued = false;
        while (!stop_requested.load(std::memory_order_acquire)) {
            @autoreleasepool {
                PendingAccessUnit first;
                {
                    std::lock_guard<std::mutex> lock(state_mutex);
                    if (pending.valid) {
                        first = std::move(pending);
                        pending = {};
                    }
                }
                if (first.valid) {
                    if (!enqueue(std::move(first.access_unit),
                                 first.timestamp_100ns)) {
                        if (!stop_requested.load()) break;
                    } else if (!first_enqueued) {
                        first_enqueued = true;
                        log(obn::source::LL_INFO,
                            "mac_player: first video sample enqueued");
                    }
                    continue;
                }

                Bambu_Sample sample{};
                const int rc = Bambu_ReadSample(tunnel, &sample);
                if (rc == Bambu_would_block) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(5));
                    continue;
                }
                if (rc == Bambu_stream_end) {
                    fail(-26, "camera stream ended", true);
                    break;
                }
                if (rc != Bambu_success) {
                    const char* detail = Bambu_GetLastErrorMsg();
                    fail(-27, std::string("camera sample read failed") +
                              (detail && *detail ? ": " + std::string(detail) : ""),
                         true);
                    break;
                }
                if (!sample.buffer || sample.size <= 0) continue;

                obn::h264::AccessUnit access_unit;
                const auto parsed = obn::h264::annexb_to_avcc(
                    sample.buffer, static_cast<std::size_t>(sample.size),
                    &access_unit);
                if (parsed != obn::h264::ParseResult::Ok) {
                    fail(-28, std::string("invalid H.264 access unit: ") +
                              obn::h264::parse_result_string(parsed), false);
                    continue;
                }
                if (access_unit.avcc.empty()) continue;
                if (!enqueue(std::move(access_unit), sample.decode_time)) {
                    if (!stop_requested.load()) break;
                } else if (!first_enqueued) {
                    first_enqueued = true;
                    log(obn::source::LL_INFO,
                        "mac_player: first video sample enqueued");
                }
            }
        }
        playing.store(false, std::memory_order_release);
        log(obn::source::LL_INFO, "mac_player: sample worker stopped");
    }

    void stop_worker()
    {
        stop_requested.store(true, std::memory_order_release);
        if (worker.joinable() && worker.get_id() != std::this_thread::get_id()) {
            worker.join();
        }
        playing.store(false, std::memory_order_release);
    }
};

void tunnel_logger(void* context, int level, const BambuChar* message)
{
    auto* state = static_cast<MacPlayerState*>(context);
    if (state && message) {
        PlayerLogger callback = nullptr;
        const void* player_context = nullptr;
        {
            std::lock_guard<std::mutex> lock(state->state_mutex);
            callback = state->player_logger;
            player_context = state->player_log_context;
        }
        if (callback) callback(player_context, level, message);
    }
    Bambu_FreeLogMsg(message);
}

void attach_layer_to_view(AVSampleBufferDisplayLayer* layer, NSView* view)
{
    void (^attach)(void) = ^{
        view.wantsLayer = YES;
        layer.frame = view.bounds;
        layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        layer.videoGravity = AVLayerVideoGravityResizeAspect;
        [view.layer addSublayer:layer];
    };
    if ([NSThread isMainThread]) attach();
    else dispatch_sync(dispatch_get_main_queue(), attach);
}

} // namespace

__attribute__((visibility("default")))
@interface BambuPlayer : NSObject {
@private
    AVSampleBufferDisplayLayer* _displayLayer;
    AVSampleBufferRenderSynchronizer* _synchronizer;
    MacPlayerState* _state;
}

- (instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer*)layer;
- (instancetype)initWithImageView:(NSView*)view;
- (int)open:(const char*)url;
- (NSSize)videoSize;
- (int)play;
- (void)stop;
- (void)close;
- (void)setLogger:(PlayerLogger)logger withContext:(const void*)context;

@end
@implementation BambuPlayer

+ (void)initialize
{
    if (self == [BambuPlayer class]) Bambu_Init();
}

- (instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer*)layer
{
    self = [super init];
    if (!self) return nil;
    _displayLayer = [layer retain];
    if (!_displayLayer) {
        [self release];
        return nil;
    }
    _synchronizer = create_render_synchronizer(_displayLayer);
    _state = new MacPlayerState();
    _state->layer = _displayLayer;
    return self;
}

- (instancetype)initWithImageView:(NSView*)view
{
    self = [super init];
    if (!self) return nil;
    _displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
    _synchronizer = create_render_synchronizer(_displayLayer);
    _state = new MacPlayerState();
    _state->layer = _displayLayer;
    attach_layer_to_view(_displayLayer, view);
    return self;
}

- (void)setLogger:(PlayerLogger)logger withContext:(const void*)context
{
    if (!_state) return;
    std::lock_guard<std::mutex> lock(_state->state_mutex);
    _state->player_logger = logger;
    _state->player_log_context = context;
}

- (int)open:(const char*)url
{
    [self close];
    if (!_state || !url || !*url) return -1;

    _state->log(obn::source::LL_INFO, "mac_player: opening LAN camera");
    Bambu_Tunnel tunnel = nullptr;
    int rc = Bambu_Create(&tunnel, url);
    if (rc != Bambu_success || !tunnel) {
        _state->fail(-10, "could not create camera tunnel", false);
        return rc == Bambu_success ? -1 : rc;
    }
    Bambu_SetLogger(tunnel, tunnel_logger, _state);
    rc = Bambu_Open(tunnel);
    if (rc != Bambu_success) {
        const char* detail = Bambu_GetLastErrorMsg();
        _state->fail(-11, std::string("could not open camera tunnel") +
                          (detail && *detail ? ": " + std::string(detail) : ""),
                     false);
        Bambu_Destroy(tunnel);
        return rc;
    }

    while ((rc = Bambu_StartStream(tunnel, true)) == Bambu_would_block) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    if (rc != Bambu_success) {
        _state->fail(-12, "could not start camera stream", false);
        Bambu_Destroy(tunnel);
        return rc;
    }

    Bambu_StreamInfo info{};
    if (Bambu_GetStreamCount(tunnel) < 1 ||
        Bambu_GetStreamInfo(tunnel, 0, &info) != Bambu_success ||
        info.type != VIDE || info.sub_type != AVC1) {
        _state->fail(-13, "camera did not expose an H.264 video track", false);
        Bambu_Destroy(tunnel);
        return -1;
    }
    _state->frame_rate = info.format.video.frame_rate > 0 ?
                         info.format.video.frame_rate : 30;
    _state->tunnel = tunnel;

    // Orca checks videoSize immediately after open returns and only calls
    // play when the width is valid. Wait for the first IDR (the existing
    // passthrough prefixes its cached SPS/PPS), then preserve that access
    // unit for the playback worker.
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::seconds(8);
    while (std::chrono::steady_clock::now() < deadline) {
        Bambu_Sample sample{};
        rc = Bambu_ReadSample(tunnel, &sample);
        if (rc == Bambu_would_block) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }
        if (rc != Bambu_success) break;
        if (!sample.buffer || sample.size <= 0) continue;

        obn::h264::AccessUnit access_unit;
        const auto parsed = obn::h264::annexb_to_avcc(
            sample.buffer, static_cast<std::size_t>(sample.size),
            &access_unit);
        if (parsed != obn::h264::ParseResult::Ok) continue;
        if (!_state->update_format(access_unit) || access_unit.avcc.empty()) {
            continue;
        }
        {
            std::lock_guard<std::mutex> lock(_state->state_mutex);
            _state->pending.access_unit = std::move(access_unit);
            _state->pending.timestamp_100ns = sample.decode_time;
            _state->pending.valid = true;
        }
        _state->log(obn::source::LL_INFO,
                    "mac_player: camera open and first access unit buffered");
        return Bambu_success;
    }

    const char* detail = Bambu_GetLastErrorMsg();
    _state->fail(-14, std::string("timed out waiting for H.264 parameter sets") +
                      (detail && *detail ? ": " + std::string(detail) : ""),
                 false);
    Bambu_Close(tunnel);
    Bambu_Destroy(tunnel);
    _state->tunnel = nullptr;
    return -1;
}

- (NSSize)videoSize
{
    if (!_state) return NSMakeSize(0, 0);
    std::lock_guard<std::mutex> lock(_state->state_mutex);
    return NSMakeSize(_state->width, _state->height);
}

- (int)play
{
    if (!_state || !_state->tunnel) return -1;
    if (_state->playing.exchange(true)) return Bambu_success;
    if (_state->worker.joinable()) _state->worker.join();
    _state->stop_requested.store(false, std::memory_order_release);
    if (renderer_status(_displayLayer) ==
        AVQueuedSampleBufferRenderingStatusFailed) {
        renderer_flush(_displayLayer, false);
    }
    std::uint64_t start_timestamp_100ns = 0;
    {
        std::lock_guard<std::mutex> lock(_state->state_mutex);
        if (_state->pending.valid) {
            start_timestamp_100ns = _state->pending.timestamp_100ns;
        }
    }
    [_synchronizer setRate:1.0f
                       time:CMTimeMake(
                                static_cast<std::int64_t>(start_timestamp_100ns),
                                10'000'000)];
    _state->worker = std::thread([state = _state] { state->run(); });
    return Bambu_success;
}

- (void)stop
{
    if (!_state) return;
    _state->stop_worker();
    _synchronizer.rate = 0.0f;
    renderer_flush(_displayLayer, false);
}

- (void)close
{
    if (!_state) return;
    _state->stop_worker();
    _synchronizer.rate = 0.0f;
    if (_state->tunnel) {
        Bambu_Close(_state->tunnel);
        Bambu_Destroy(_state->tunnel);
        _state->tunnel = nullptr;
    }
    {
        std::lock_guard<std::mutex> lock(_state->state_mutex);
        _state->pending = {};
        _state->width = 0;
        _state->height = 0;
    }
    _state->sps.clear();
    _state->pps.clear();
    _state->have_timestamp = false;
    if (_state->format) {
        CFRelease(_state->format);
        _state->format = nullptr;
    }
    renderer_flush(_displayLayer, true);
}

- (void)dealloc
{
    [self close];
    delete _state;
    _state = nullptr;
    [_displayLayer removeFromSuperlayer];
    [_synchronizer release];
    _synchronizer = nil;
    [_displayLayer release];
    _displayLayer = nil;
    [super dealloc];
}

@end
