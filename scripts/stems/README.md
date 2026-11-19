# Stem model (Demucs htdemucs → ONNX)

Pregame separates stems with Demucs v4 (`htdemucs`, MIT) running in ONNX Runtime (MIT, Core ML provider). The app ships `Models/htdemucs.onnx` and `Models/htdemucs.onnx.data`. The STFT/iSTFT, segmentation and overlap-add are done in Swift (`Sources/PregameCore/Stems.swift`).

## Rebuild the model

Only needed if the model files are lost.

```sh
python3 -m venv venv && ./venv/bin/pip install torch torchaudio demucs onnx onnxruntime onnxscript dora-search omegaconf einops julius openunmix diffq soundfile
git clone https://github.com/sevagh/demucs.onnx.git      # its demucs-for-onnx moves the STFT out of the network
PYTHONPATH=demucs.onnx/demucs-for-onnx ./venv/bin/python demucs.onnx/scripts/convert-pth-to-onnx.py out
cp out/htdemucs.onnx out/htdemucs.onnx.data ../../Models/
```

## Check it

- `ref_np.py <44.1 kHz wav> <htdemucs.onnx>`: the same algorithm in NumPy, compared with PyTorch Demucs. Expect 80–95 dB agreement per stem. It writes `ref_in.npy`/`ref_out.npy`.
- `PREGAME_STEM_REF=<dir with those npy files> swift test -c release --filter StemTests`: the Swift pipeline against the NumPy reference. Expect about 110–130 dB.

## Benchmarks (Apple M4, 2026-10-23)

| Engine | Speed |
|---|---|
| PyTorch on the GPU (MPS) | ~12× realtime |
| ONNX Runtime with Core ML | ~11× realtime (chosen: native, no Python) |
| ONNX Runtime, CPU only | ~6.5× realtime |
| demucs.cpp | ~1× realtime |

The first Core ML load compiles for ~40 s; after that it's cached in `Caches/Pregame/CoreML`: inside the app's container (`~/Library/Containers/com.prafuljoshi.pregame/Data/Library/…`) for the sandboxed app, or `~/Library/Caches/Pregame/CoreML` for an unsandboxed debug run.
