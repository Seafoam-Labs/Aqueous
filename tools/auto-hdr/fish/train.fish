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

set -l index $DATA_DIR/pairs/index.jsonl
if not test -f $index
    echo "corpus index not found: $index" >&2
    echo "run fish/make_corpus.fish first" >&2
    exit 1
end

exec $root/.venv/bin/python $root/tools/train.py \
    --option $AUTO_HDR_OPTION \
    --index $index \
    --run-dir $RUN_DIR \
    $argv
