# Vendored: WebRTC AEC3

The echo canceller from WebRTC, as packaged by the PulseAudio project
(webrtc-audio-processing 2.1), with the abseil-cpp release it pins
(20240722.0). Only the files AEC3 compiles against are here: `MANIFEST`
lists them, and it was derived from what the linker pulls in for
`../webrtc_aec.cc` and the headers those files include.

Nothing here is edited. To update or verify, fetch the two tarballs and run

    bash scripts/vendor-webrtc-aec.sh [--check] <webrtc-audio-processing-2.1.tar.xz> <abseil-cpp-20240722.0.tar.gz>

Licences: WebRTC is BSD-3-Clause with an additional patent grant
(`webrtc-audio-processing/webrtc/LICENSE`, `PATENTS`, `COPYING`);
abseil-cpp is Apache-2.0 (`abseil-cpp/LICENSE`).
