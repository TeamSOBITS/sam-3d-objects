#!/bin/bash
# Setup script for SAM 3D Objects (see doc/setup.md, docs/issue.md)
# Checkpoints are not downloaded here (see doc/setup.md "2. Getting Checkpoints").
set -euo pipefail

ENV_NAME="sam3d-objects"

echo "╔══╣ Setup: SAM 3D Objects (STARTING) ╠══╗"

cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    echo "ERROR: linux-64 platform is required (got $(uname -s)/$(uname -m))." >&2
    exit 1
fi

if ! command -v nvidia-smi > /dev/null 2>&1; then
    echo "WARNING: nvidia-smi not found. A NVIDIA GPU (>= 32GB VRAM) is required to run inference."
fi

# Build CUDA extensions (e.g. pytorch3d) even when no GPU is visible,
# otherwise they fail at runtime with "Not compiled with GPU support".
export FORCE_CUDA=1

# Remove Python 3.12 paths added by ROS / ~/.bashrc (see docs/issue.md)
unset PYTHONPATH
export PYTHONNOUSERSITE=1

# Select micromamba (preferred) or conda
if command -v micromamba > /dev/null 2>&1; then
    CONDA_CMD=micromamba
    eval "$(micromamba shell hook --shell bash)"
elif command -v conda > /dev/null 2>&1; then
    CONDA_CMD=conda
    eval "$(conda shell.bash hook)"
else
    echo "ERROR: micromamba or conda not found. See docs/issue.md." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
if ${CONDA_CMD} env list --json | grep -q "/envs/${ENV_NAME}\""; then
    echo "Environment '${ENV_NAME}' already exists, skipping creation."
elif [ "${CONDA_CMD}" = micromamba ]; then
    micromamba create -y -n "${ENV_NAME}" -f environments/default.yml
else
    conda env create -n "${ENV_NAME}" -f environments/default.yml
fi

# Activation hooks may reference unset variables
set +u
${CONDA_CMD} activate "${ENV_NAME}"
set -u

# Isolate PYTHONPATH / CUDA_HOME on every activation (see docs/issue.md)
mkdir -p "${CONDA_PREFIX}/etc/conda/activate.d" "${CONDA_PREFIX}/etc/conda/deactivate.d"
cat > "${CONDA_PREFIX}/etc/conda/activate.d/sam3d_env.sh" << 'EOF'
export _SAM3D_OLD_PYTHONPATH="${PYTHONPATH}"
export _SAM3D_OLD_CUDA_HOME="${CUDA_HOME}"
unset PYTHONPATH
export PYTHONNOUSERSITE=1
export CUDA_HOME="${CONDA_PREFIX}"
EOF
cat > "${CONDA_PREFIX}/etc/conda/deactivate.d/sam3d_env.sh" << 'EOF'
[ -n "${_SAM3D_OLD_PYTHONPATH}" ] && export PYTHONPATH="${_SAM3D_OLD_PYTHONPATH}"
if [ -n "${_SAM3D_OLD_CUDA_HOME}" ]; then export CUDA_HOME="${_SAM3D_OLD_CUDA_HOME}"; else unset CUDA_HOME; fi
unset _SAM3D_OLD_PYTHONPATH _SAM3D_OLD_CUDA_HOME PYTHONNOUSERSITE
EOF
export CUDA_HOME="${CONDA_PREFIX}"

echo "python: $(which python) ($(python --version))"
echo "nvcc:   $(which nvcc)"

# ---------------------------------------------------------------------------
# Python dependencies
# ---------------------------------------------------------------------------
# pytorch/cuda dependencies
export PIP_EXTRA_INDEX_URL="https://pypi.ngc.nvidia.com https://download.pytorch.org/whl/cu121"
python -m pip install -e '.[dev]'
python -m pip install -e '.[p3d]'  # pytorch3d dependency on pytorch is broken, 2-step install

# inference dependencies
export PIP_FIND_LINKS="https://nvidia-kaolin.s3.us-east-2.amazonaws.com/torch-2.5.1_cu121.html"
python -m pip install -e '.[inference]'

# Patch hydra (https://github.com/facebookresearch/hydra/pull/2863)
python ./patching/hydra

# ---------------------------------------------------------------------------
# Verify (see docs/issue.md)
# ---------------------------------------------------------------------------
python - << 'EOF'
import os, sys, torch
prefix = os.environ["CONDA_PREFIX"]
print(f"python: {sys.version.split()[0]}")
print(f"torch:  {torch.__version__} ({torch.__file__}), cuda {torch.version.cuda}")
errors = []
if not torch.__file__.startswith(prefix):
    errors.append(f"torch is loaded from outside the environment: {torch.__file__}")
if torch.version.cuda != "12.1":
    errors.append(f"torch CUDA version is {torch.version.cuda}, expected 12.1")
if not torch.cuda.is_available():
    print("WARNING: torch.cuda.is_available() is False (no GPU visible).")
if errors:
    sys.exit("ERROR: " + "\nERROR: ".join(errors))
EOF
if ! nvcc --version | grep -q "release 12.1"; then
    echo "ERROR: nvcc is not CUDA 12.1 ($(which nvcc))." >&2
    exit 1
fi

echo "╚══╣ Setup: SAM 3D Objects (FINISHED) ╠══╝"
