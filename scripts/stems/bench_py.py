import sys, time, torch
from demucs.pretrained import get_model
from demucs.apply import apply_model
from demucs.audio import AudioFile
dev = sys.argv[1]
model = get_model("htdemucs"); model.to(dev).eval()
for path in sys.argv[2:]:
    wav = AudioFile(path).read(streams=0, samplerate=model.samplerate, channels=model.audio_channels)
    dur = wav.shape[-1] / model.samplerate
    ref = wav.mean(0); wav = (wav - ref.mean()) / ref.std()
    t = time.time()
    with torch.no_grad():
        out = apply_model(model, wav[None].to(dev), shifts=0, split=True, overlap=0.25, device=dev)[0]
    if dev == "mps": torch.mps.synchronize()
    el = time.time() - t
    print(f"{dev} {el:6.1f}s for {dur:5.0f}s audio ({dur/el:4.1f}x realtime)  {path.split('/')[-1]}", flush=True)
