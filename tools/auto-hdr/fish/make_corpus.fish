#!/usr/bin/env fish
# Synthesize (SDR, HDR) training pairs from everything under $DATA_DIR/raw
# and register UI negatives from $UI_DIR (screenshots) if it is set.
# Extra args pass through, e.g. --exposures 1 or --mappers bt2390,hable.
set -l here (cd (dirname (status filename)); and pwd)
set -l root (dirname $here)
set -q DATA_DIR; or set -l DATA_DIR $root/data
set -l python $root/.venv-rocm/bin/python
if set -q AUTO_HDR_VENV
    set python $AUTO_HDR_VENV/bin/python
end
if set -q AUTO_HDR_PYTHON
    set python $AUTO_HDR_PYTHON
end

set -l extra $argv
if set -q UI_DIR
    set extra $extra --ui-dir $UI_DIR
end

$python $root/tools/generate_pairs.py \
    --hdr-root $DATA_DIR/raw \
    --out-dir $DATA_DIR/pairs \
    --index $DATA_DIR/pairs/index.jsonl \
    $extra
or exit 1
