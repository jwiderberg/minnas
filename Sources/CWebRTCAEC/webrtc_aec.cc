#include "webrtc_aec.h"

#include <memory>

#include "api/audio/audio_processing.h"
#include "api/audio/echo_canceller3_config.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"
#include "modules/audio_processing/audio_buffer.h"
#include "rtc_base/logging.h"

struct webrtc_aec {
  webrtc::StreamConfig config{WEBRTC_AEC_SAMPLE_RATE, 1};
  webrtc::AudioBuffer render{WEBRTC_AEC_SAMPLE_RATE, 1, WEBRTC_AEC_SAMPLE_RATE, 1, WEBRTC_AEC_SAMPLE_RATE, 1};
  webrtc::AudioBuffer capture{WEBRTC_AEC_SAMPLE_RATE, 1, WEBRTC_AEC_SAMPLE_RATE, 1, WEBRTC_AEC_SAMPLE_RATE, 1};
  std::unique_ptr<webrtc::EchoCanceller3> canceller;
};

// AEC3's defaults with a longer linear filter: 32 blocks (128 ms at
// 16 kHz) instead of 13 (52 ms), so the filter covers more of a room's
// reverberant tail and the suppressor has less residual echo to remove
// while both sides talk. Measured through Whisper on 12 synthetic
// double-talk cases: words of the near speaker lost 37% -> 18% (3% vs 31%
// with the echo as loud as the speaker), far-end words leaked 0% either way.
// 20, 24, 40 and 48 blocks all did worse than 32.
static webrtc::EchoCanceller3Config webrtc_aec_config() {
  webrtc::EchoCanceller3Config config;
  config.filter.refined.length_blocks = 32;
  config.filter.refined_initial.length_blocks = 32;
  config.filter.coarse.length_blocks = 32;
  config.filter.coarse_initial.length_blocks = 32;
  return config;
}

webrtc_aec *webrtc_aec_create(void) {
  // WebRTC logs to stderr by default; the app has its own log.
  rtc::LogMessage::LogToDebug(rtc::LS_NONE);
  try {
    auto aec = std::make_unique<webrtc_aec>();
    aec->canceller = std::make_unique<webrtc::EchoCanceller3>(
        webrtc_aec_config(), std::nullopt, WEBRTC_AEC_SAMPLE_RATE, 1, 1);
    return aec.release();
  } catch (...) {
    return nullptr;
  }
}

void webrtc_aec_process(webrtc_aec *aec, const float *render, const float *capture, float *out) {
  const float *renderChannels[1] = {render};
  aec->render.CopyFrom(renderChannels, aec->config);
  aec->canceller->AnalyzeRender(&aec->render);

  const float *captureChannels[1] = {capture};
  aec->capture.CopyFrom(captureChannels, aec->config);
  aec->canceller->AnalyzeCapture(&aec->capture);
  aec->canceller->ProcessCapture(&aec->capture, /*level_change=*/false);
  float *outChannels[1] = {out};
  aec->capture.CopyTo(aec->config, outChannels);
}

void webrtc_aec_metrics(const webrtc_aec *aec, double *erl_db, double *erle_db) {
  const auto metrics = aec->canceller->GetMetrics();
  if (erl_db) *erl_db = metrics.echo_return_loss;
  if (erle_db) *erle_db = metrics.echo_return_loss_enhancement;
}

void webrtc_aec_destroy(webrtc_aec *aec) { delete aec; }
