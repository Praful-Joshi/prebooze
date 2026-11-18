#include "demucs_onnx.h"
#include "onnxruntime_c_api.h"
#include "coreml_provider_factory.h"
#include <stdio.h>
#include <string.h>

static _Thread_local char last_error[512];
static const OrtApi *api(void) { return OrtGetApiBase()->GetApi(ORT_API_VERSION); }

/// Record and release an OrtStatus; returns 1 if it was an error.
static int failed(OrtStatus *s) {
    if (!s) return 0;
    snprintf(last_error, sizeof last_error, "%s", api()->GetErrorMessage(s));
    api()->ReleaseStatus(s);
    return 1;
}

struct hz_demucs {
    OrtEnv *env;
    OrtSession *session;
    OrtMemoryInfo *mem;
    char *in_names[2], *out_names[2];
};

const char *hz_demucs_last_error(void) { return last_error; }

void hz_demucs_close(hz_demucs *d) {
    if (!d) return;
    OrtAllocator *alloc = NULL;
    api()->GetAllocatorWithDefaultOptions(&alloc);
    for (int i = 0; i < 2; i++) {
        if (d->in_names[i]) api()->AllocatorFree(alloc, d->in_names[i]);
        if (d->out_names[i]) api()->AllocatorFree(alloc, d->out_names[i]);
    }
    if (d->mem) api()->ReleaseMemoryInfo(d->mem);
    if (d->session) api()->ReleaseSession(d->session);
    if (d->env) api()->ReleaseEnv(d->env);
    free(d);
}

hz_demucs *hz_demucs_open(const char *model_path, const char *cache_dir, int use_coreml) {
    last_error[0] = 0;
    const OrtApi *a = api();
    if (!a) { snprintf(last_error, sizeof last_error, "ONNX Runtime API version mismatch"); return NULL; }
    hz_demucs *d = calloc(1, sizeof *d);
    OrtSessionOptions *opts = NULL;
    if (failed(a->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "harmonizer", &d->env))) goto fail;
    if (failed(a->CreateSessionOptions(&opts))) goto fail;
    if (failed(a->SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL))) goto fail;
    if (use_coreml) {
        const char *keys[4] = { kCoremlProviderOption_MLComputeUnits, kCoremlProviderOption_ModelFormat,
                                kCoremlProviderOption_RequireStaticInputShapes, kCoremlProviderOption_ModelCacheDirectory };
        const char *vals[4] = { kCoremlProviderOption_MLComputeUnits_ALL, "MLProgram", "1", cache_dir };
        if (failed(a->SessionOptionsAppendExecutionProvider(opts, "CoreML", keys, vals, cache_dir ? 4 : 3))) goto fail;
    }
    if (failed(a->CreateSession(d->env, model_path, opts, &d->session))) goto fail;
    a->ReleaseSessionOptions(opts); opts = NULL;
    if (failed(a->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &d->mem))) goto fail;
    OrtAllocator *alloc = NULL;
    if (failed(a->GetAllocatorWithDefaultOptions(&alloc))) goto fail;
    for (size_t i = 0; i < 2; i++) {
        if (failed(a->SessionGetInputName(d->session, i, alloc, &d->in_names[i]))) goto fail;
        if (failed(a->SessionGetOutputName(d->session, i, alloc, &d->out_names[i]))) goto fail;
    }
    return d;
fail:
    if (opts) a->ReleaseSessionOptions(opts);
    hz_demucs_close(d);
    return NULL;
}

int hz_demucs_run(hz_demucs *d, const float *mix, const float *mag, float *out_spec, float *out_time) {
    last_error[0] = 0;
    const OrtApi *a = api();
    int64_t mix_shape[3] = { 1, 2, HZ_DEMUCS_SEGMENT };
    int64_t mag_shape[4] = { 1, 4, HZ_DEMUCS_FREQS, HZ_DEMUCS_FRAMES };
    int64_t spec_shape[5] = { 1, HZ_DEMUCS_SOURCES, 4, HZ_DEMUCS_FREQS, HZ_DEMUCS_FRAMES };
    int64_t time_shape[4] = { 1, HZ_DEMUCS_SOURCES, 2, HZ_DEMUCS_SEGMENT };
    size_t n_mix = 2 * (size_t)HZ_DEMUCS_SEGMENT, n_mag = 4 * (size_t)HZ_DEMUCS_FREQS * HZ_DEMUCS_FRAMES;
    size_t n_spec = HZ_DEMUCS_SOURCES * n_mag, n_time = HZ_DEMUCS_SOURCES * n_mix;
    OrtValue *in[2] = { NULL, NULL }, *out[2] = { NULL, NULL };
    int rc = 1;
    if (failed(a->CreateTensorWithDataAsOrtValue(d->mem, (void *)mix, n_mix * sizeof(float), mix_shape, 3,
                                                 ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &in[0]))) goto done;
    if (failed(a->CreateTensorWithDataAsOrtValue(d->mem, (void *)mag, n_mag * sizeof(float), mag_shape, 4,
                                                 ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &in[1]))) goto done;
    if (failed(a->CreateTensorWithDataAsOrtValue(d->mem, out_spec, n_spec * sizeof(float), spec_shape, 5,
                                                 ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &out[0]))) goto done;
    if (failed(a->CreateTensorWithDataAsOrtValue(d->mem, out_time, n_time * sizeof(float), time_shape, 4,
                                                 ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &out[1]))) goto done;
    if (failed(a->Run(d->session, NULL, (const char *const *)d->in_names, (const OrtValue *const *)in, 2,
                      (const char *const *)d->out_names, 2, out))) goto done;
    rc = 0;
done:
    for (int i = 0; i < 2; i++) {
        if (in[i]) a->ReleaseValue(in[i]);
        if (out[i]) a->ReleaseValue(out[i]);
    }
    return rc;
}
