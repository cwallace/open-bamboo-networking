// Private declaration of the BambuSource C ABI shared by the exported
// implementation and the macOS Objective-C player adapter.
#pragma once

#include <cstdint>

extern "C" {

using Bambu_Tunnel = void*;

#if defined(_WIN32)
using BambuChar = wchar_t;
#else
using BambuChar = char;
#endif

enum Bambu_StreamType { VIDE = 0, AUDI = 1 };
enum Bambu_VideoSubType { AVC1 = 0, MJPG = 1 };
enum Bambu_FormatType {
    video_avc_packet = 0,
    video_avc_byte_stream,
    video_jpeg,
    audio_raw,
    audio_adts,
};
enum Bambu_Error {
    Bambu_success = 0,
    Bambu_stream_end,
    Bambu_would_block,
    Bambu_buffer_limit,
};

struct Bambu_StreamInfo {
    int type;
    int sub_type;
    union {
        struct {
            int width;
            int height;
            int frame_rate;
        } video;
        struct {
            int sample_rate;
            int channel_count;
            int sample_size;
        } audio;
    } format;
    int                  format_type;
    int                  format_size;
    int                  max_frame_size;
    const unsigned char* format_buffer;
};

struct Bambu_Sample {
    int                  itrack;
    int                  size;
    int                  flags;
    const unsigned char* buffer;
    unsigned long long   decode_time; // 100 ns units
};

using BambuLogger = void (*)(void* context, int level,
                             const BambuChar* message);

int Bambu_Init();
void Bambu_Deinit();
int Bambu_Create(Bambu_Tunnel* tunnel, const char* path);
void Bambu_SetLogger(Bambu_Tunnel tunnel, BambuLogger logger, void* context);
int Bambu_Open(Bambu_Tunnel tunnel);
int Bambu_StartStream(Bambu_Tunnel tunnel, bool video);
int Bambu_GetStreamCount(Bambu_Tunnel tunnel);
int Bambu_GetStreamInfo(Bambu_Tunnel tunnel, int index,
                        Bambu_StreamInfo* info);
int Bambu_ReadSample(Bambu_Tunnel tunnel, Bambu_Sample* sample);
void Bambu_Close(Bambu_Tunnel tunnel);
void Bambu_Destroy(Bambu_Tunnel tunnel);
const char* Bambu_GetLastErrorMsg();
void Bambu_FreeLogMsg(const BambuChar* message);

} // extern "C"
