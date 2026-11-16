// C interface to WebRTC's AEC3 echo canceller, for Swift.
// Mono, 16 kHz, 10 ms frames (160 samples), float samples in [-1, 1].
#ifndef WEBRTC_AEC_H
#define WEBRTC_AEC_H
#ifdef __cplusplus
extern "C" {
#endif

typedef struct webrtc_aec webrtc_aec;

enum { WEBRTC_AEC_SAMPLE_RATE = 16000, WEBRTC_AEC_FRAME = 160 };

/// The output lags the capture input by this many samples (AEC3 works in
/// 64-sample blocks inside the 160-sample frames). Callers that need the
/// output on the input's timeline drop this many samples from the front
/// and flush with silent frames at the end.
enum { WEBRTC_AEC_LATENCY = 128 };

/// A new canceller with AEC3's default configuration. NULL on failure
/// (allocation; no C++ exception crosses this interface).
webrtc_aec *webrtc_aec_create(void);

/// One 10 ms frame. `render` is the far-end signal (what the speakers
/// played), `capture` the microphone; `out` receives the microphone with
/// the echo removed. Each points at WEBRTC_AEC_FRAME samples; `out` may
/// alias `capture`.
void webrtc_aec_process(webrtc_aec *aec, const float *render, const float *capture, float *out);

/// AEC3's own estimates: echo return loss and its enhancement, in dB.
void webrtc_aec_metrics(const webrtc_aec *aec, double *erl_db, double *erle_db);

void webrtc_aec_destroy(webrtc_aec *aec);

#ifdef __cplusplus
}
#endif
#endif
