#!/usr/bin/env fish
# Create the Python venv for the Auto HDR training stack and install deps.
set -l here (cd (dirname (status filename)); and pwd)
set -l root (dirname $here)
cd $root

if not test -d .venv
    echo "creating venv at $root/.venv"
    python3 -m venv .venv
end

./.venv/bin/pip install --upgrade pip
./.venv/bin/pip install -r requirements.txt

echo ""
echo "torch device check:"
./.venv/bin/python -c 'import torch; print("torch", torch.__version__); print("cuda/rocm available:", torch.cuda.is_available()); print("device:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "cpu")'
