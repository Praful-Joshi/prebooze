// Mirrors Mixxx 2.5: src/analyzer/plugins/analyzerqueenmary{key,beats}.cpp and
// buffering_utils.cpp (DownmixAndOverlapHelper), fed in Mixxx-sized chunks.

#include "qmdsp_shim.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <vector>

#include "dsp/keydetection/GetKeyMode.h"
#include "dsp/onsets/DetectionFunction.h"
#include "dsp/tempotracking/TempoTrackV2.h"
#include "maths/MathUtilities.h"

namespace {

constexpr long kAnalysisFramesPerChunk = 4096;  // Mixxx analyzer/constants.h

// Window/step framing of a mono stream; the first frame is centred in the
// first window (write position starts at windowSize / 2).
class OverlapHelper {
  public:
    using Callback = std::function<bool(double *, size_t)>;

    OverlapHelper(size_t windowSize, size_t stepSize, Callback cb)
        : m_buffer(windowSize, 0.0), m_window(windowSize), m_step(stepSize),
          m_write(windowSize / 2), m_cb(std::move(cb)) {}

    bool process(const float *in, size_t frames) { return inner(in, frames); }

    bool finalize() {
        size_t toFill = m_window - m_write;
        size_t frames = std::max(toFill, m_window / 2 - 1);
        return inner(nullptr, frames);
    }

  private:
    bool inner(const float *in, size_t frames) {
        size_t read = 0;
        while (read < frames) {
            size_t n = std::min(frames - read, m_window - m_write);
            for (size_t i = 0; i < n; ++i) {
                m_buffer[m_write + i] = in ? static_cast<double>(in[read + i]) : 0.0;
            }
            m_write += n;
            read += n;
            if (m_write == m_window) {
                if (!m_cb(m_buffer.data(), m_window)) {
                    return false;
                }
                std::memmove(m_buffer.data(), m_buffer.data() + m_step,
                             (m_window - m_step) * sizeof(double));
                m_write -= m_step;
            }
        }
        return true;
    }

    std::vector<double> m_buffer;
    size_t m_window, m_step, m_write;
    Callback m_cb;
};

}  // namespace

extern "C" int qm_detect_key(const float *mono, long frames, double sampleRate) {
    if (!mono || frames <= 0 || sampleRate <= 0) {
        return 0;
    }
    GetKeyMode::Config config(sampleRate, 440.0f);
    GetKeyMode keyMode(config);
    std::vector<std::pair<int, double>> changes;  // (key, start frame)
    int prevKey = 0;
    long currentFrame = 0;
    bool ok = true;
    OverlapHelper helper(keyMode.getBlockSize(), keyMode.getHopSize(),
                         [&](double *window, size_t) {
                             int key = keyMode.process(window);
                             if (key < 1 || key > 24) {
                                 ok = false;
                                 return false;
                             }
                             if (key != prevKey) {
                                 changes.emplace_back(key, static_cast<double>(currentFrame));
                                 prevKey = key;
                             }
                             return true;
                         });
    for (long pos = 0; pos < frames && ok; pos += kAnalysisFramesPerChunk) {
        long n = std::min(kAnalysisFramesPerChunk, frames - pos);
        currentFrame += n;  // Mixxx advances the frame counter before processing
        helper.process(mono + pos, static_cast<size_t>(n));
    }
    if (ok) {
        helper.finalize();
    }
    if (changes.empty()) {
        return 0;
    }
    if (changes.size() == 1) {
        return changes[0].first;
    }
    std::map<int, double> histogram;  // ordered like Mixxx's QMap
    for (size_t i = 0; i < changes.size(); ++i) {
        double next = (i + 1 == changes.size()) ? static_cast<double>(frames)
                                                 : changes[i + 1].second;
        histogram[changes[i].first] += next - changes[i].second;
    }
    int best = 0;
    double bestLen = 0;
    for (const auto &kv : histogram) {
        if (kv.second > bestLen) {
            best = kv.first;
            bestLen = kv.second;
        }
    }
    return best;
}

extern "C" int qm_detect_beats(const float *mono, long frames, double sampleRate,
                               double **outBeats) {
    *outBeats = nullptr;
    if (!mono || frames <= 0 || sampleRate <= 0) {
        return 0;
    }
    const int stepSize = static_cast<int>(sampleRate * 0.01161f);
    const int windowSize = MathUtilities::nextPowerOfTwo(static_cast<int>(sampleRate / 50));

    DFConfig config;
    config.DFType = DF_COMPLEXSD;
    config.stepSize = stepSize;
    config.frameLength = windowSize;
    config.dbRise = 3;
    config.adaptiveWhitening = false;
    config.whiteningRelaxCoeff = -1;
    config.whiteningFloor = -1;
    DetectionFunction detection(config);

    std::vector<double> results;
    OverlapHelper helper(windowSize, stepSize, [&](double *window, size_t) {
        results.push_back(detection.processTimeDomain(window));
        return true;
    });
    for (long pos = 0; pos < frames; pos += kAnalysisFramesPerChunk) {
        long n = std::min(kAnalysisFramesPerChunk, frames - pos);
        helper.process(mono + pos, static_cast<size_t>(n));
    }
    helper.finalize();

    int nonZero = static_cast<int>(results.size());
    while (nonZero > 0 && results[nonZero - 1] <= 0.0) {
        --nonZero;
    }
    std::vector<double> df, beatPeriod, tempi, beats;
    for (int i = 2; i < nonZero; ++i) {  // skip the first 2, like Mixxx/vamp
        df.push_back(results[i]);
        beatPeriod.push_back(0.0);
    }
    if (df.empty()) {
        return 0;
    }
    TempoTrackV2 tracker(static_cast<float>(sampleRate), stepSize);
    tracker.calculateBeatPeriod(df, beatPeriod, tempi);
    tracker.calculateBeats(df, beatPeriod, beats);

    double *out = static_cast<double *>(std::malloc(sizeof(double) * std::max<size_t>(beats.size(), 1)));
    for (size_t i = 0; i < beats.size(); ++i) {
        out[i] = beats[i] * stepSize + stepSize / 2;  // integer half step, as Mixxx
    }
    *outBeats = out;
    return static_cast<int>(beats.size());
}

extern "C" void qm_free(void *ptr) { std::free(ptr); }
