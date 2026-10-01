"""Phonon-2 (.fermion) -> four Core ML models for HoTty.

  PhononFrontend.mlpackage  one function per bucket, "s<seconds>": audio [1, seconds * 16000] zero-padded,
                            length [1] = real sample count -> features [1, F, 128], frames [1]
                            (log-mel, normalized; fp32 on the CPU: its sums overflow fp16)
  PhononEncoder.mlpackage   same buckets: features, frames -> enc [1, T, 640], enc_length [1]
                            (conformer + projector; fp16, sized for the Neural Engine)
  PhononDecoder.mlpackage   token [1, 1], h/c [2, 1, 640] -> dec [1, 640], h, c   (LSTM prediction net, one step)
  PhononJoint.mlpackage     enc [1, 640], dec [1, 640] -> token [1], duration [1]  (argmaxes)

The published weights are a five-value quantized parakeet-tdt-0.6b-v3: expanded, they load
into the stock transformers ParakeetForTDT, which is traced here. The encoder's five-value
rows (and the int6 tables) keep their exact values through Core ML's per-row lookup tables.

Usage: python convert.py OUTDIR [--container model.fermion] [--check clip.wav ...] [--no-convert]
Run through scripts/convert-phonon.sh, which sets up the environment and installs the result.
"""
import argparse
import json
import math
import os
import sys

import numpy as np
import soundfile as sf
import torch
import torch.nn as nn

sys.path.insert(0, os.path.dirname(__file__))
from fermion_container import read_container  # noqa: E402

BASE = "nvidia/parakeet-tdt-0.6b-v3"
REPO = "FermionResearch/Phonon-2"
ARCHIVE = "phonon-2.bps.tar.zst"
ARCHIVE_SHA256 = "98125795b6dda72f5c6eee9ba33d19815df65dcb18b50a357bf9f73c9935309e"
# Fixed input lengths (seconds), one traced function each: the transformers encoder bakes its
# sequence length into the graph, and the Neural Engine only runs fixed shapes. The real length
# masks the padding out. Each size costs a one-time ~2 minute Neural Engine compile per Mac.
BUCKETS = [4, 10, 30]


def fetch_container(workdir):
    """Downloads the published archive, checks its pinned digest and unpacks model.fermion."""
    import hashlib
    import tarfile

    import zstandard
    from huggingface_hub import hf_hub_download

    path = hf_hub_download(REPO, ARCHIVE)
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    assert h.hexdigest() == ARCHIVE_SHA256, f"{ARCHIVE} digest mismatch: {h.hexdigest()}"
    with open(path, "rb") as f, zstandard.ZstdDecompressor().stream_reader(f) as z, tarfile.open(fileobj=z, mode="r|") as t:
        for m in t:
            if m.name.endswith("model.fermion"):
                out = os.path.join(workdir, "model.fermion")
                with open(out, "wb") as dst:
                    dst.write(t.extractfile(m).read())
                return out
    raise RuntimeError(f"no model.fermion in {ARCHIVE}")


def load_model(container):
    """Expands the container into the stock ParakeetForTDT (fp32), as Fermion's reference_transformers.py does."""
    import re

    from transformers import AutoProcessor, GenerationConfig, ParakeetForTDT, ParakeetTDTConfig

    tensors, _ = read_container(container)
    sd = {}
    for k, v in tensors.items():
        if k.endswith("num_batches_tracked"):
            v32 = float(np.asarray(v, dtype=np.float32).reshape(-1)[0])
            sd[k] = torch.tensor(int(v32) if np.isfinite(v32) else 0, dtype=torch.int64)
        else:
            arr = np.ascontiguousarray(v.astype(np.float32))
            if arr.ndim == 2 and re.search(r"\.conv\.pointwise_conv[12]\.weight$", k):
                arr = arr[:, :, None]
            sd[k] = torch.from_numpy(arr)
    model = ParakeetForTDT(ParakeetTDTConfig.from_pretrained(BASE))
    missing, unexpected = model.load_state_dict(sd, strict=False)
    if missing or unexpected:
        raise RuntimeError(f"weights don't fit ParakeetForTDT: missing {missing[:5]} unexpected {unexpected[:5]}")
    model.eval()
    model.generation_config = GenerationConfig.from_pretrained(BASE)
    return model, AutoProcessor.from_pretrained(BASE)


class Frontend(nn.Module):
    """ParakeetFeatureExtractor for one utterance, written with conv1d so it converts cleanly."""

    def __init__(self, fe):
        super().__init__()
        self.n_fft, self.hop, self.preemph = fe.n_fft, fe.hop_length, fe.preemphasis
        win = torch.hann_window(fe.win_length, periodic=False, dtype=torch.float64)
        lpad = (fe.n_fft - fe.win_length) // 2
        win = nn.functional.pad(win, (lpad, fe.n_fft - fe.win_length - lpad))
        n = torch.arange(fe.n_fft, dtype=torch.float64)
        k = torch.arange(fe.n_fft // 2 + 1, dtype=torch.float64)[:, None]
        ang = 2 * math.pi * k * n / fe.n_fft
        self.register_buffer("cos_k", (torch.cos(ang) * win)[:, None, :].float())
        self.register_buffer("sin_k", (-torch.sin(ang) * win)[:, None, :].float())
        self.register_buffer("mel", fe.mel_filters.float())

    def forward(self, audio, length):  # [1, N], [1] int32 real samples
        n = audio.shape[1]
        valid = (torch.arange(n)[None, :] < length[:, None]).float()
        x = torch.cat([audio[:, :1], audio[:, 1:] - self.preemph * audio[:, :-1]], dim=1) * valid
        x = nn.functional.pad(x, (self.n_fft // 2, self.n_fft // 2))[:, None, :]
        re = nn.functional.conv1d(x, self.cos_k, stride=self.hop)
        im = nn.functional.conv1d(x, self.sin_k, stride=self.hop)
        power = re * re + im * im                               # [1, 257, F]
        mel = torch.log(torch.matmul(self.mel, power) + 2 ** -24)  # [1, 128, F]
        frames = torch.div(length, self.hop, rounding_mode="floor")  # valid frames, as the extractor counts them
        mask = (torch.arange(mel.shape[2])[None, :] < frames[:, None])  # [1, F]
        m = mask[:, None, :].float()
        cnt = frames.float()[:, None, None]
        mean = (mel * m).sum(dim=2, keepdim=True) / cnt
        var = (((mel - mean) * m) ** 2).sum(dim=2, keepdim=True) / (cnt - 1)
        mel = (mel - mean) / (torch.sqrt(var) + 1e-5) * m
        return mel.transpose(1, 2), frames.to(torch.int32)     # [1, F, 128], [1]


def _attention_fp16_safe(self, hidden_states, position_embeddings, attention_mask=None, **kwargs):
    """ParakeetEncoderAttention.forward (eager), filling masked scores with -1e4 instead of
    float32's minimum, which is -inf in fp16 and turns fully masked (padding) rows into NaN."""
    b, t = hidden_states.shape[:2]
    heads, hd = self.config.num_attention_heads, self.head_dim
    q = self.q_proj(hidden_states).view(b, t, -1, hd).transpose(1, 2)
    k = self.k_proj(hidden_states).view(b, t, -1, hd).transpose(1, 2)
    v = self.v_proj(hidden_states).view(b, t, -1, hd).transpose(1, 2)
    q_u = q + self.bias_u.view(1, heads, 1, hd)
    q_v = q + self.bias_v.view(1, heads, 1, hd)
    rel = self.relative_k_proj(position_embeddings).view(b, -1, heads, hd)
    bd = self._rel_shift(q_v @ rel.permute(0, 2, 3, 1))[..., :t] * self.scaling
    if attention_mask is not None:
        bd = bd.masked_fill(attention_mask.logical_not(), -1e4)
    w = torch.softmax(torch.matmul(q_u, k.transpose(2, 3)) * self.scaling + bd, dim=-1)
    out = torch.matmul(w, v).transpose(1, 2).reshape(b, t, -1)
    return self.o_proj(out), None


class Encoder(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.encoder = model.encoder
        self.proj = model.encoder_projector
        for layer in self.encoder.layers:
            layer.self_attn.forward = _attention_fp16_safe.__get__(layer.self_attn)

    def forward(self, features, frames):
        mask = (torch.arange(features.shape[1], device=frames.device)[None, :] < frames[:, None]).long()
        out = self.encoder(input_features=features, attention_mask=mask)
        return self.proj(out.last_hidden_state), out.attention_mask.sum(-1).to(torch.int32)


class Decoder(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.d = model.decoder

    def forward(self, token, h, c):
        e = self.d.embedding(token)
        out, (h2, c2) = self.d.lstm(e, (h, c))
        return self.d.decoder_projector(out)[:, 0, :], h2, c2


class Joint(nn.Module):
    def __init__(self, model, vocab):
        super().__init__()
        self.j = model.joint
        self.vocab = vocab

    def forward(self, enc, dec):
        logits = self.j.head(self.j.activation(enc + dec))
        tok = torch.argmax(logits[:, : self.vocab], dim=-1).to(torch.int32)
        dur = torch.argmax(logits[:, self.vocab:], dim=-1).to(torch.int32)
        return tok, dur


def detok(pieces, ids):
    return "".join(pieces[i] for i in ids).replace("\u2581", " ").strip()


def greedy(enc_frames, step_dec, step_joint, blank, durations, layers, hidden):
    """TDT greedy decode, as transformers' ParakeetTDTGenerationMixin does it."""
    h = np.zeros((layers, 1, hidden), np.float32)
    c = np.zeros((layers, 1, hidden), np.float32)
    dec, h, c = step_dec(blank, h, c)
    out, t, T, here = [], 0, enc_frames.shape[0], 0
    while t < T:
        tok, di = step_joint(enc_frames[t], dec)
        d = durations[di]
        if tok == blank:
            d, here = max(d, 1), 0
        else:
            out.append(tok)
            dec, h, c = step_dec(tok, h, c)
            here = here + 1 if d == 0 else 0
            if here >= 10:  # NeMo's max symbols per step
                d, here = 1, 0
        t += d
    return out


def bucket(n):
    return next((b * 16000 for b in BUCKETS if b * 16000 >= n), n)


def run_torch_encoder(front_m, enc_m, w):
    padded = np.zeros(bucket(len(w)), np.float32)
    padded[: len(w)] = w
    feats, frames = front_m(torch.from_numpy(padded)[None], torch.tensor([len(w)], dtype=torch.int32))
    enc, n = enc_m(feats, frames)
    return enc.numpy()[0][: int(n[0])], int(n[0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--container", help="a local model.fermion (default: download and verify the published one)")
    ap.add_argument("--check", nargs="*", default=[])
    ap.add_argument("--no-convert", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    container = a.container or fetch_container(a.out)
    model, processor = load_model(container)
    cfg = model.config
    fe = processor.feature_extractor
    vocab, blank = cfg.vocab_size, cfg.blank_token_id
    durations = list(cfg.durations)
    layers, hidden = cfg.num_decoder_layers, cfg.decoder_hidden_size
    print("vocab", vocab, "blank", blank, "durations", durations, "decoder", layers, hidden)

    front_m, enc_m = Frontend(fe).eval(), Encoder(model).eval()
    dec_m, joint_m = Decoder(model).eval(), Joint(model, vocab).eval()
    tok = processor.tokenizer
    pieces = [tok.convert_ids_to_tokens(i) for i in range(vocab)]

    def torch_dec(t, h, c):
        with torch.no_grad():
            d, h2, c2 = dec_m(torch.tensor([[t]]), torch.from_numpy(h), torch.from_numpy(c))
        return d.numpy()[0], h2.numpy(), c2.numpy()

    def torch_joint(e, d):
        with torch.no_grad():
            t, di = joint_m(torch.from_numpy(e)[None], torch.from_numpy(d)[None])
        return int(t[0]), int(di[0])

    clips = {}
    for p in a.check:
        w, sr = sf.read(p, dtype="float32", always_2d=True)
        assert sr == 16000, p
        clips[p] = w.mean(axis=1)
        with torch.no_grad():
            inp = processor([clips[p]], sampling_rate=16000, return_tensors="pt")
            ref_ids = model.generate(input_features=inp["input_features"], attention_mask=inp["attention_mask"])
            ref = processor.batch_decode(getattr(ref_ids, "sequences", ref_ids), skip_special_tokens=True)[0].strip()
            enc, n = run_torch_encoder(front_m, enc_m, clips[p])
        ids = greedy(enc, torch_dec, torch_joint, blank, durations, layers, hidden)
        mine = detok(pieces, ids)
        print(f"[torch] {'MATCH' if mine == ref else 'DIFF '} {p}\n  ref:  {ref}\n  mine: {mine}")

    # Tokenizer pieces for Swift: id -> piece (SentencePiece, '▁' marks a word start).
    json.dump({"pieces": pieces, "blank": blank, "buckets": BUCKETS, "durations": durations,
               "decoder_layers": layers, "decoder_hidden": hidden, "sample_rate": 16000},
              open(os.path.join(a.out, "phonon-vocab.json"), "w"))
    if a.no_convert:
        return

    import coremltools as ct
    import coremltools.optimize.coreml as cto

    target = ct.target.macOS15
    # Five-value rows have at most 5 distinct weights and int6 rows at most 64: a per-row lookup
    # table holds them exactly.
    lut = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(
        mode="unique", granularity="per_grouped_channel", group_size=1, weight_threshold=4096))

    def per_bucket(name, build):
        """One traced function per bucket, saved as one multifunction package (shared weights stored once)."""
        parts = os.path.join(a.out, f"{name}-parts")
        os.makedirs(parts, exist_ok=True)
        desc = ct.utils.MultiFunctionDescriptor()
        for b in BUCKETS:
            path = os.path.join(parts, f"s{b}.mlpackage")
            if not os.path.exists(path):
                build(b * 16000).save(path)
                print(f"{name} s{b} converted", flush=True)
            desc.add_function(path, src_function_name="main", target_function_name=f"s{b}")
        desc.default_function_name = f"s{BUCKETS[0]}"
        out = os.path.join(a.out, f"{name}.mlpackage")
        ct.utils.save_multifunction(desc, out)
        return out

    def build_frontend(n):
        traced = torch.jit.trace(front_m, (torch.zeros(1, n), torch.tensor([n], dtype=torch.int32)))
        return ct.convert(
            traced, inputs=[ct.TensorType("audio", shape=(1, n), dtype=np.float32),
                            ct.TensorType("length", shape=(1,), dtype=np.int32)],
            outputs=[ct.TensorType("features", dtype=np.float32), ct.TensorType("frames", dtype=np.int32)],
            minimum_deployment_target=target, compute_precision=ct.precision.FLOAT32,
            compute_units=ct.ComputeUnit.CPU_ONLY, skip_model_load=True)

    def build_encoder(n):
        f = n // 160 + 1
        traced = torch.jit.trace(enc_m, (torch.zeros(1, f, 128), torch.tensor([f - 1], dtype=torch.int32)))
        m = ct.convert(
            traced, inputs=[ct.TensorType("features", shape=(1, f, 128), dtype=np.float32),
                            ct.TensorType("frames", shape=(1,), dtype=np.int32)],
            outputs=[ct.TensorType("enc", dtype=np.float32), ct.TensorType("enc_length", dtype=np.int32)],
            minimum_deployment_target=target, compute_units=ct.ComputeUnit.CPU_AND_NE, skip_model_load=True)
        return cto.palettize_weights(m, lut)

    front_path = per_bucket("PhononFrontend", build_frontend)
    enc_path = per_bucket("PhononEncoder", build_encoder)

    h0 = torch.zeros(layers, 1, hidden)
    dec_ml = ct.convert(
        torch.jit.trace(dec_m, (torch.zeros(1, 1, dtype=torch.int32), h0, h0)),
        inputs=[ct.TensorType("token", shape=(1, 1), dtype=np.int32),
                ct.TensorType("h", shape=(layers, 1, hidden), dtype=np.float32),
                ct.TensorType("c", shape=(layers, 1, hidden), dtype=np.float32)],
        outputs=[ct.TensorType("dec", dtype=np.float32), ct.TensorType("h_out", dtype=np.float32),
                 ct.TensorType("c_out", dtype=np.float32)],
        minimum_deployment_target=target, compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY)
    dec_ml = cto.palettize_weights(dec_ml, lut)
    dec_ml.save(os.path.join(a.out, "PhononDecoder.mlpackage"))

    joint_ml = ct.convert(
        torch.jit.trace(joint_m, (torch.zeros(1, hidden), torch.zeros(1, hidden))),
        inputs=[ct.TensorType("enc", shape=(1, hidden), dtype=np.float32),
                ct.TensorType("dec", shape=(1, hidden), dtype=np.float32)],
        outputs=[ct.TensorType("token", dtype=np.int32), ct.TensorType("duration", dtype=np.int32)],
        minimum_deployment_target=target, compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY)
    joint_ml = cto.palettize_weights(joint_ml, lut)
    joint_ml.save(os.path.join(a.out, "PhononJoint.mlpackage"))

    def ml_dec(t, h, c):
        r = dec_ml.predict({"token": np.array([[t]], np.int32), "h": h, "c": c})
        return r["dec"][0].astype(np.float32), r["h_out"].astype(np.float32), r["c_out"].astype(np.float32)

    def ml_joint(e, d):
        r = joint_ml.predict({"enc": e[None].astype(np.float32), "dec": d[None].astype(np.float32)})
        return int(r["token"].reshape(-1)[0]), int(r["duration"].reshape(-1)[0])

    for p, w in clips.items():
        size = bucket(len(w))
        padded = np.zeros(size, np.float32)
        padded[: len(w)] = w
        fn = f"s{size // 16000}"
        front_ml = ct.models.MLModel(front_path, function_name=fn, compute_units=ct.ComputeUnit.CPU_ONLY)
        # CPU here keeps the check quick; HoTty runs this encoder on the Neural Engine.
        enc_ml = ct.models.MLModel(enc_path, function_name=fn, compute_units=ct.ComputeUnit.CPU_ONLY)
        f = front_ml.predict({"audio": padded[None], "length": np.array([len(w)], np.int32)})
        r = enc_ml.predict({"features": f["features"], "frames": f["frames"].astype(np.int32)})
        enc = r["enc"][0][: int(r["enc_length"].reshape(-1)[0])]
        ids = greedy(enc, ml_dec, ml_joint, blank, durations, layers, hidden)
        print(f"[coreml] {p}\n  {detok(pieces, ids)}")


if __name__ == "__main__":
    main()
