#!/usr/bin/env fish
# Create the ROCm-enabled Python venv for the Auto HDR training stack.
set -l here (cd (dirname (status filename)); and pwd)
set -l root (dirname $here)
set -l venv $root/.venv-rocm
if set -q AUTO_HDR_VENV
    set venv $AUTO_HDR_VENV
end
set -l bootstrap_python python3.12
if set -q AUTO_HDR_BOOTSTRAP_PYTHON
    set bootstrap_python $AUTO_HDR_BOOTSTRAP_PYTHON
end
set -q AUTO_HDR_REQUIRE_ROCM; or set -l AUTO_HDR_REQUIRE_ROCM 1
cd $root

if not test -d $venv
    echo "creating venv at $venv"
    if not command -q $bootstrap_python
        echo "Python 3.12 is required for AMD's validated Ryzen ROCm wheels." >&2
        echo "Install python3.12 or set AUTO_HDR_BOOTSTRAP_PYTHON to its path." >&2
        exit 1
    end
    $bootstrap_python -m venv $venv
    or exit 1
end

$venv/bin/python -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 12) else 1)'
or begin
    echo "ROCm venv must use Python 3.12: $venv" >&2
    echo "choose a new AUTO_HDR_VENV or recreate this environment" >&2
    exit 1
end

$venv/bin/python -m pip install --upgrade pip wheel
or exit 1
$venv/bin/python -m pip install --upgrade -r requirements.txt
or exit 1

echo ""
echo "PyTorch accelerator check:"
set -l check_args
if test "$AUTO_HDR_REQUIRE_ROCM" = 1
    set check_args --require-rocm
end
$venv/bin/python $root/tools/check_accelerator.py $check_args
or exit 1

echo ""
echo "Auto HDR Python: $venv/bin/python"
