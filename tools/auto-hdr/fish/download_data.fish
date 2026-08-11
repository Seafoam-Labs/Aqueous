#!/usr/bin/env fish
# Download the Poly Haven HDRI catalog (CC0) with a provenance manifest.
# Extra args pass through to the downloader, e.g.:
#   fish download_data.fish --limit 10                        # smoke pull
#   fish download_data.fish --categories skies sunrise-sunset --min-evs 20
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

mkdir -p $DATA_DIR/raw
$python $root/tools/download_polyhaven.py \
    --out $DATA_DIR/raw/polyhaven \
    --manifest $DATA_DIR/polyhaven_manifest.jsonl \
    --res 4k $argv
or exit 1

echo ""
echo "Optional Category B corpora (large; pull manually as needed)."
echo "--max-workers 2 avoids HF Xet rate limits (429); log in for higher limits."
echo "  huggingface-cli download --repo-type dataset iimmortall/S2R-HDR --local-dir $DATA_DIR/raw/s2r-hdr --max-workers 2"
echo "  huggingface-cli download --repo-type dataset iimmortall/S2R-HDR-2 --local-dir $DATA_DIR/raw/s2r-hdr-2 --max-workers 2"
echo "  huggingface-cli download --repo-type dataset zlicastro/zanya-unreal-engine-hdr-dataset --local-dir $DATA_DIR/raw/zanya-ue5 --max-workers 2"
echo "  huggingface-cli download --repo-type dataset ZhengGuangze/HDRI --local-dir $DATA_DIR/raw/hdri-skies --max-workers 2"
echo "  huggingface-cli download --repo-type dataset Temporarium/HDR_Photos_VAE_Training_DNG --local-dir $DATA_DIR/raw/hdr-dng --max-workers 2"
