#!/usr/bin/env fish
# Evaluate a checkpoint against the test split and the mandatory baselines
# (no-op + Stage A analytic curve). Defaults to the best checkpoint of
# AUTO_HDR_OPTION's run dir; override with AUTO_HDR_CKPT.
set -l here (cd (dirname (status filename)); and pwd)
set -l root (dirname $here)
set -q DATA_DIR; or set -l DATA_DIR $root/data
set -q RUN_DIR; or set -l RUN_DIR $root/runs
set -q AUTO_HDR_OPTION; or set -l AUTO_HDR_OPTION A
set -q AUTO_HDR_CKPT; or set -l AUTO_HDR_CKPT $RUN_DIR/option(string lower $AUTO_HDR_OPTION)/best.pt
set -l python $root/.venv-rocm/bin/python
if set -q AUTO_HDR_VENV
    set python $AUTO_HDR_VENV/bin/python
end
if set -q AUTO_HDR_PYTHON
    set python $AUTO_HDR_PYTHON
end

if not test -f $AUTO_HDR_CKPT
    echo "checkpoint not found: $AUTO_HDR_CKPT" >&2
    echo "set AUTO_HDR_CKPT or train first (fish/train.fish)" >&2
    exit 1
end

exec $python $root/tools/evaluate.py \
    --ckpt $AUTO_HDR_CKPT \
    --index $DATA_DIR/pairs/index.jsonl \
    --out (dirname $AUTO_HDR_CKPT)/results.json \
    $argv
