#ifndef DEMUCS_ONNX_H
#define DEMUCS_ONNX_H

/// Minimal C wrapper over ONNX Runtime for the Demucs (htdemucs) core network
/// exported with its STFT moved outside (demucs.onnx). One segment per call.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hz_demucs hz_demucs;

/// Segment length in samples (7.8 s at 44.1 kHz) and spectrogram shape.
enum { HZ_DEMUCS_SEGMENT = 343980, HZ_DEMUCS_FREQS = 2048, HZ_DEMUCS_FRAMES = 336, HZ_DEMUCS_SOURCES = 4 };

/// Open the model. `cache_dir` (may be NULL) keeps the Core ML compilation
/// between launches. Returns NULL on failure (see hz_demucs_last_error()).
hz_demucs *hz_demucs_open(const char *model_path, const char *cache_dir, int use_coreml);

/// Run one segment.
///   mix:      2 × SEGMENT (channel-major), normalised audio
///   mag:      4 × FREQS × FRAMES (L.re, L.im, R.re, R.im)
///   out_spec: SOURCES × 4 × FREQS × FRAMES
///   out_time: SOURCES × 2 × SEGMENT
/// Returns 0 on success.
int hz_demucs_run(hz_demucs *d, const float *mix, const float *mag, float *out_spec, float *out_time);

void hz_demucs_close(hz_demucs *d);

/// The last error message (thread-local; empty if none).
const char *hz_demucs_last_error(void);

#ifdef __cplusplus
}
#endif
#endif
