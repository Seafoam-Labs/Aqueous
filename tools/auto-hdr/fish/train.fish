#!/usr/bin/env fish
# Kick off training. Architecture comes from AUTO_HDR_OPTION (A|B|C),
# defaults to A (the gain-field CNN target).
#
#   set AUTO_HDR_OPTION C; fish train.fish --smoke 64 --epochs 2 --workers 0
#       -> pipeline shakedown on a tiny subset (M1, Option C)
#   fish train.fish
#       -> full Option A run (M3)
#
# All extra args pass through to tools/train.py (--epochs, --batch, --lr,
# --base, --resume runs/optiona/last.pt, ...).
set -l here (cd (dirname (status filename)); and pwd)
set -l root (dirname $here)
set -q DATA_DIR; or set -l DATA_DIR $root/data
set -q RUN_DIR; or set -l RUN_DIR $root/runs
set -q AUTO_HDR_OPTION; or set -l AUTO_HDR_OPTION A
set -q AUTO_HDR_DEVICE; or set -l AUTO_HDR_DEVICE rocm

set -l python $root/.venv-rocm/bin/python
if set -q AUTO_HDR_VENV
    set python $AUTO_HDR_VENV/bin/python
end
if set -q AUTO_HDR_PYTHON
    set python $AUTO_HDR_PYTHON
end
if not test -x $python
    echo "Auto HDR Python is not executable: $python" >&2
    echo "run 'fish fish/setup.fish' or set AUTO_HDR_PYTHON" >&2
    exit 1
end

set -l index $DATA_DIR/pairs/index.jsonl
if not test -f $index
    echo "corpus index not found: $index" >&2
    echo "run fish/make_corpus.fish first" >&2
    exit 1
end

exec $python $root/tools/train.py \
    --option $AUTO_HDR_OPTION \
    --device $AUTO_HDR_DEVICE \
    --index $index \
    --run-dir $RUN_DIR \
    $argv
