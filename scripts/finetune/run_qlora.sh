#!/bin/bash
# QLoRA fine-tune of the polish model on locally collected correction pairs,
# then fuse → GGUF → Ollama import. Runs entirely on this machine.
#
# Pipeline (each step gated on the previous):
#   1. mlx_lm.lora     — QLoRA on the 4-bit base (peak RAM ~7-9GB on qwen3:8b)
#   2. mlx_lm.fuse     — merge adapters; --de-quantize is REQUIRED, the GGUF
#                        converter rejects mlx-quantized weights (mlx-examples#1382)
#   3. convert_hf_to_gguf.py + llama-quantize (llama.cpp)
#   4. ollama create   — Modelfile FROM the GGUF; TEMPLATE must match the
#                        official qwen3 template or the JSON contract breaks
#
# Ollama ADAPTER import is NOT an option: adapters are only supported for
# Llama/Mistral/Gemma architectures, and mlx adapters are not PEFT format.
#
# Prereqs: pip install mlx-lm ; a llama.cpp checkout with convert script;
#          data prepared by prepare_polish_dataset.py (train/valid jsonl).
set -euo pipefail

MODEL="${VELORA_FT_BASE:-mlx-community/Qwen3-8B-4bit}"
DATA_DIR="${1:-data/polish}"
OUT_DIR="${2:-build/finetune}"
LLAMA_CPP="${LLAMA_CPP:-$HOME/workspace/llama.cpp}"
ITERS="${VELORA_FT_ITERS:-600}"

[ -f "$DATA_DIR/train.jsonl" ] || { echo "missing $DATA_DIR/train.jsonl — run prepare_polish_dataset.py first"; exit 1; }
command -v mlx_lm.lora >/dev/null || { echo "pip install mlx-lm"; exit 1; }

mkdir -p "$OUT_DIR"

echo "== 1/4 QLoRA training ($ITERS iters, base=$MODEL) =="
mlx_lm.lora \
  --model "$MODEL" \
  --train \
  --data "$DATA_DIR" \
  --adapter-path "$OUT_DIR/adapters" \
  --iters "$ITERS" \
  --batch-size 2 \
  --mask-prompt

echo "== 2/4 fuse (de-quantized fp16 output) =="
mlx_lm.fuse \
  --model "$MODEL" \
  --adapter-path "$OUT_DIR/adapters" \
  --save-path "$OUT_DIR/fused" \
  --de-quantize

echo "== 3/4 GGUF conversion + Q4_K_M quantization =="
[ -f "$LLAMA_CPP/convert_hf_to_gguf.py" ] || { echo "llama.cpp not found at $LLAMA_CPP (set LLAMA_CPP=...)"; exit 1; }
python3 "$LLAMA_CPP/convert_hf_to_gguf.py" "$OUT_DIR/fused" --outfile "$OUT_DIR/velora-polish-f16.gguf"
"$LLAMA_CPP/build/bin/llama-quantize" "$OUT_DIR/velora-polish-f16.gguf" "$OUT_DIR/velora-polish-q4km.gguf" Q4_K_M

echo "== 4/4 Ollama import =="
# Reuse the official qwen3 template/params so Velora's prompts behave identically.
ollama show qwen3:8b --template > "$OUT_DIR/qwen3.template"
cat > "$OUT_DIR/Modelfile" <<EOF
FROM $OUT_DIR/velora-polish-q4km.gguf
TEMPLATE """$(cat "$OUT_DIR/qwen3.template")"""
PARAMETER temperature 0.1
PARAMETER repeat_penalty 1.0
EOF
ollama create velora-polish -f "$OUT_DIR/Modelfile"

echo
echo "done. A/B it against the stock model with the existing eval gates:"
echo "  VELORA_OLLAMA_MODEL=velora-polish python3 pocs/tuning/repair_eval.py"
echo "  VELORA_OLLAMA_MODEL=velora-polish python3 pocs/tuning/format_eval.py"
echo "then set VELORA_OLLAMA_MODEL=velora-polish for the app if it wins."
