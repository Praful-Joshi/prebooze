import sys, time, numpy as np, onnxruntime as ort
path = sys.argv[1]
for name, prov in [("CPU", ["CPUExecutionProvider"]),
                   ("CoreML", [("CoreMLExecutionProvider", {"MLComputeUnits": "ALL", "ModelFormat": "MLProgram"}), "CPUExecutionProvider"])]:
    try:
        so = ort.SessionOptions(); so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        t0 = time.time(); s = ort.InferenceSession(path, so, providers=prov); load = time.time() - t0
        feeds = {i.name: np.random.randn(*[d if isinstance(d, int) else 1 for d in i.shape]).astype(np.float32) for i in s.get_inputs()}
        s.run(None, feeds)
        t = time.time(); n = 3
        for _ in range(n): s.run(None, feeds)
        per = (time.time() - t) / n
        # A 7.8 s segment with 25% overlap advances 5.85 s of audio.
        print(f"{name}: load {load:.1f}s, {per:.2f}s per segment -> ~{5.85/per:.1f}x realtime", flush=True)
    except Exception as e:
        print(name, "failed:", str(e)[:300])
