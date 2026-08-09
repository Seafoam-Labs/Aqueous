#!/usr/bin/env fish
# Download the Poly Haven HDRI catalog (CC0) with a provenance manifest.
# Extra args pass through to the downloader, e.g.:
#   fish download_data.fish --limit 10                        # smoke pull
#   fish download_data.fish --categories skies sunrise-sunset --min-evs 20
set -l here (cd (dirname (status filename)); and pwd)
set -l root (dirname $here)
set -q DATA_DIR; or set -l DATA_DIR $root/data

mkdir -p $DATA_DIR/raw
$root/.venv/bin/python $root/tools/download_polyhaven.py \
    --out $DATA_DIR/raw/polyhaven \
    --manifest $DATA_DIR/polyhaven_manifest.jsonl \
    --res 4k $argv
or exit 1

echo ""
echo "Optional Category B corpora (large; pull manually as needed):"
echo "  huggingface-cli download --repo-type dataset iimmortall/S2R-HDR --local-dir $DATA_DIR/raw/s2r-hdr"
echo "  huggingface-cli download --repo-type dataset iimmortall/S2R-HDR-2 --local-dir $DATA_DIR/raw/s2r-hdr-2"
echo "  huggingface-cli download --repo-type dataset zlicastro/zanya-unreal-engine-hdr-dataset --local-dir $DATA_DIR/raw/zanya-ue5"
echo "  huggingface-cli download --repo-type dataset ZhengGuangze/HDRI --local-dir $DATA_DIR/raw/hdri-skies"
echo "  huggingface-cli download --repo-type dataset Temporarium/HDR_Photos_VAE_Training_DNG --local-dir $DATA_DIR/raw/hdr-dng"
