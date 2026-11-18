"""Demucs htdemucs separation with ONNX Runtime + NumPy STFT (the algorithm the
Swift port follows), compared against PyTorch demucs.apply_model."""
import sys, time, numpy as np, onnxruntime as ort, soundfile as sf

NFFT, HOP, SEG = 4096, 1024, 343980

def stft(x):            # x: (C, N) -> complex (C, 2049, frames); torch.stft normalized, center, reflect
    win = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(NFFT) / NFFT)   # periodic hann
    xp = np.pad(x, ((0, 0), (NFFT // 2, NFFT // 2)), mode="reflect")
    n = 1 + (xp.shape[1] - NFFT) // HOP
    idx = np.arange(NFFT)[None, :] + HOP * np.arange(n)[:, None]
    frames = xp[:, idx] * win                                       # (C, n, NFFT)
    return (np.fft.rfft(frames, axis=-1) / np.sqrt(NFFT)).transpose(0, 2, 1)

def istft(z, length):    # z: (C, 2049, frames) -> (C, length); torch.istft normalized, center
    win = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(NFFT) / NFFT)
    frames = np.fft.irfft(z.transpose(0, 2, 1) * np.sqrt(NFFT), n=NFFT, axis=-1) * win
    C, n, _ = frames.shape
    total = NFFT + HOP * (n - 1)
    y = np.zeros((C, total)); wsum = np.zeros(total)
    for k in range(n):
        y[:, k * HOP:k * HOP + NFFT] += frames[:, k]; wsum[k * HOP:k * HOP + NFFT] += win ** 2
    y /= np.where(wsum > 1e-11, wsum, 1)
    return y[:, NFFT // 2: NFFT // 2 + length]

def spec(x):             # standalone_spec
    le = int(np.ceil(x.shape[-1] / HOP)); pad = HOP // 2 * 3
    xp = np.pad(x, ((0, 0), (pad, pad + le * HOP - x.shape[-1])), mode="reflect")
    return stft(xp)[:, :-1, 2:2 + le]

def ispec(z, length):    # standalone_ispec
    z = np.pad(z, ((0, 0), (0, 1), (2, 2)))
    pad = HOP // 2 * 3; le = HOP * int(np.ceil(length / HOP)) + 2 * pad
    return istft(z, le)[:, pad:pad + length]

def run_segment(sess, chunk):       # chunk: (2, SEG)
    z = spec(chunk)                                                  # (2, 2048, 336)
    mag = np.stack([z.real, z.imag], 1).reshape(4, *z.shape[1:])     # cac: (C*2, F, T) as [L.re, L.im, R.re, R.im]
    names = [i.name for i in sess.get_inputs()]
    xs, xt = sess.run(None, {names[0]: chunk[None].astype(np.float32), names[1]: mag[None].astype(np.float32)})
    S = xs.shape[1]
    zout = xs[0].reshape(S, 2, 2, *xs.shape[-2:])                    # (S, C, re/im, F, T)
    zc = zout[:, :, 0] + 1j * zout[:, :, 1]
    return np.stack([ispec(zc[s], SEG) for s in range(S)]) + xt[0]   # (S, 2, SEG)

def separate(sess, wav):            # wav: (2, N) float at 44.1 kHz
    ref = wav.mean(0); m, sd = ref.mean(), ref.std()
    mix = (wav - m) / sd
    N = mix.shape[1]; stride = int(0.75 * SEG)
    w = np.concatenate([np.arange(1, SEG // 2 + 1), np.arange(SEG - SEG // 2, 0, -1)]).astype(np.float64); w /= w.max()
    out = np.zeros((4, 2, N)); wsum = np.zeros(N)
    for off in range(0, N, stride):
        L = min(SEG, N - off); delta = SEG - L
        start = off - delta // 2; cs, ce = max(0, start), min(N, start + SEG)
        chunk = np.pad(mix[:, cs:ce], ((0, 0), (cs - start, start + SEG - ce)))
        o = run_segment(sess, chunk)
        d = o.shape[-1] - L; o = o[..., d // 2: d // 2 + L]           # center_trim
        out[..., off:off + L] += w[:L] * o; wsum[off:off + L] += w[:L]
    return out / wsum * sd + m

if __name__ == "__main__":
    import torch
    from demucs.pretrained import get_model
    from demucs.apply import apply_model
    wav, sr = sf.read(sys.argv[1], dtype="float32", frames=44100 * 30, start=44100 * 60); wav = wav.T
    sess = ort.InferenceSession(sys.argv[2], providers=["CPUExecutionProvider"])
    t = time.time(); ours = separate(sess, wav.astype(np.float64)); print(f"onnx+numpy {time.time()-t:.1f}s")
    model = get_model("htdemucs"); model.eval()
    ref = wav.mean(0); x = torch.tensor((wav - ref.mean()) / ref.std())
    with torch.no_grad(): theirs = apply_model(model, x[None], shifts=0, split=True, overlap=0.25)[0].numpy()
    theirs = theirs * ref.std() + ref.mean()
    for i, name in enumerate(model.sources):
        err = ours[i] - theirs[i]
        sdr = 10 * np.log10((theirs[i] ** 2).sum() / max((err ** 2).sum(), 1e-12))
        print(f"{name:7s} agreement SDR {sdr:5.1f} dB")
    np.save("ref_out.npy", ours.astype(np.float32)); np.save("ref_in.npy", wav)
