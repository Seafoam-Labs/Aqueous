#!/usr/bin/env fish
# Export a checkpoint to deployment artifacts:
#   A -> ONNX gain-field graph (+ --demo <img> writes a gain.exr)
#   B -> ONNX LUT encoder (+ --demo <img> bakes lut.cube)
#   C -> ONNX boost regressor (+ --demo <img> bakes the analytic .cube)
set -l here (cd (dirname (status filename)); and pwd)
set -l root (dirname $here)
set -q RUN_DIR; or set -l RUN_DIR $root/runs
set -q AUTO_HDR_OPTION; or set -l AUTO_HDR_OPTION A
set -q AUTO_HDR_CKPT; or set -l AUTO_HDR_CKPT $RUN_DIR/option(string lower $AUTO_HDR_OPTION)/best.pt
set -q EXPORT_DIR; or set -l EXPORT_DIR $root/export

if not test -f $AUTO_HDR_CKPT
    echo "checkpoint not found: $AUTO_HDR_CKPT" >&2
    exit 1
end

mkdir -p $EXPORT_DIR
set -l name option(string lower $AUTO_HDR_OPTION)
exec $root/.venv/bin/python $root/tools/export.py \
    --ckpt $AUTO_HDR_CKPT \
    --out $EXPORT_DIR/$name.onnx \
    --demo-out $EXPORT_DIR/demo-$name \
    $argv
