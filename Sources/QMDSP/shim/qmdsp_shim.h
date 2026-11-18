// C interface to the Queen Mary DSP key and tempo detectors, configured
// exactly like Mixxx 2.5's analyzers (analyzerqueenmarykey/beats.cpp).
#ifndef QMDSP_SHIM_H
#define QMDSP_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/// Global key of a mono signal, as a Mixxx ChromaticKey:
/// 1..12 = C..B major, 13..24 = C..B minor, 0 = no key found.
int qm_detect_key(const float *mono, long frames, double sampleRate);

/// Raw beat positions (in frames) from TempoTrackV2. Returns the count and
/// stores a malloc'd array in *outBeats (free with qm_free). Mixxx's
/// constant-tempo post-processing is done on the Swift side.
int qm_detect_beats(const float *mono, long frames, double sampleRate,
                    double **outBeats);

void qm_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif
