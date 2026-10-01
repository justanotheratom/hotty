#!/bin/zsh
# Builds the Phonon-2 Core ML models HoTty runs, from Fermion Research's published weights
# (huggingface.co/FermionResearch/Phonon-2, CC-BY-4.0), and installs them where HoTty looks:
#   ~/Library/Application Support/HoTty/Models/Phonon-2
# Needs uv (https://docs.astral.sh/uv) and Xcode. Takes a few minutes; about 250 MB installed.
# Usage: scripts/convert-phonon.sh [--check clip.wav ...]   (16 kHz test clips to compare)
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=build/phonon
VENV=$WORK/venv
DEST="$HOME/Library/Application Support/HoTty/Models/Phonon-2"
mkdir -p "$WORK"

if [[ ! -x $VENV/bin/python ]]; then
  uv venv -q --python 3.12 "$VENV"
fi
uv pip install -q --python "$VENV/bin/python" "torch==2.7.*" "transformers>=5.6" "coremltools>=9" \
  numpy soundfile sentencepiece librosa huggingface_hub zstandard

"$VENV/bin/python" scripts/phonon/convert.py "$WORK/out" "$@"

rm -rf "$WORK/compiled"
mkdir -p "$WORK/compiled"
for m in PhononFrontend PhononEncoder PhononDecoder PhononJoint; do
  xcrun coremlc compile "$WORK/out/$m.mlpackage" "$WORK/compiled" >/dev/null
done
cp "$WORK/out/phonon-vocab.json" "$WORK/compiled/"

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$WORK/compiled" "$DEST"
echo "Installed Phonon-2 to $DEST ($(du -sh "$DEST" | cut -f1))"
