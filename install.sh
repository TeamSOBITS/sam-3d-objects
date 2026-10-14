#!/bin/bash
# Setup script for SAM 3D Objects (see doc/setup.md, docs/issue.md)
# Checkpoints are not downloaded here (see doc/setup.md "2. Getting Checkpoints").
# Installs torch 2.7.1+cu128 instead of upstream torch 2.5.1+cu121, which has no kernels for
# Blackwell GPUs (RTX 5090, sm_120) and fails with "no kernel image is available" (see docs/issue.md).
set -euo pipefail

echo "╔══╣ Setup: SAM 3D Objects (STARTING) ╠══╗"

cd "$(dirname "$0")"
REPO_DIR="$(pwd)"

# micromamba binary, package cache and environment are all kept inside the repository,
# so that they survive container re-creation (only colcon_ws/src is bind-mounted, see docs/issue.md)
MICROMAMBA_DIR="${REPO_DIR}/.micromamba"
MICROMAMBA="${MICROMAMBA_DIR}/bin/micromamba"
ENV_PREFIX="${MICROMAMBA_DIR}/envs/sam3d-objects"
export MAMBA_ROOT_PREFIX="${MICROMAMBA_DIR}"

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

# curl/tar/bzip2: micromamba download, git: git+ dependencies (pytorch3d, MoGe, gsplat)
missing=()
for cmd in curl tar bzip2 git; do
    command -v "${cmd}" > /dev/null 2>&1 || missing+=("${cmd}")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: missing commands: ${missing[*]} (e.g. sudo apt install ${missing[*]})" >&2
    exit 1
fi

# Build CUDA extensions (e.g. pytorch3d) even when no GPU is visible,
# otherwise they fail at runtime with "Not compiled with GPU support".
export FORCE_CUDA=1
# Target GPU architecture for the CUDA extensions (12.0: RTX 5090)
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-12.0}"

# Remove Python 3.12 paths and system CUDA 12.8 / ROS libraries added by ROS / ~/.bashrc (see docs/issue.md)
unset PYTHONPATH LD_LIBRARY_PATH LIBRARY_PATH
export PYTHONNOUSERSITE=1

# ---------------------------------------------------------------------------
# micromamba (always used, even if conda is installed; no `shell init`, see docs/issue.md)
# ---------------------------------------------------------------------------
mkdir -p "${MICROMAMBA_DIR}"
# Keep colcon / rosdep from crawling the environment (the repository is inside colcon_ws/src)
touch "${MICROMAMBA_DIR}/COLCON_IGNORE"
if [ ! -x "${MICROMAMBA}" ]; then
    echo "Installing micromamba to ${MICROMAMBA}"
    curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest \
        | tar -xj -C "${MICROMAMBA_DIR}" bin/micromamba
fi
echo "micromamba: ${MICROMAMBA} ($("${MICROMAMBA}" --version)), root prefix: ${MAMBA_ROOT_PREFIX}"
eval "$("${MICROMAMBA}" shell hook --shell bash)"

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
if [ -x "${ENV_PREFIX}/bin/python" ]; then
    # An environment created from upstream default.yml (CUDA 12.1) cannot be upgraded in place (see docs/issue.md)
    if ! "${ENV_PREFIX}/bin/nvcc" --version 2> /dev/null | grep -q "release 12.8"; then
        echo "ERROR: '${ENV_PREFIX}' is not a CUDA 12.8 environment. Remove it and re-run: rm -rf '${ENV_PREFIX}'" >&2
        exit 1
    fi
    echo "Environment '${ENV_PREFIX}' already exists, skipping creation."
else
    micromamba create -y -p "${ENV_PREFIX}" -f environments/cu128.yml
fi

# Activation hooks may reference unset variables
set +u
micromamba activate "${ENV_PREFIX}"
set -u

# Isolate PYTHONPATH / LD_LIBRARY_PATH / LIBRARY_PATH / CUDA_HOME on every activation (see docs/issue.md)
mkdir -p "${CONDA_PREFIX}/etc/conda/activate.d" "${CONDA_PREFIX}/etc/conda/deactivate.d"
cat > "${CONDA_PREFIX}/etc/conda/activate.d/sam3d_env.sh" << 'EOF'
for _sam3d_var in PYTHONPATH LD_LIBRARY_PATH LIBRARY_PATH CUDA_HOME; do
    if [ -n "${!_sam3d_var+x}" ]; then export "_SAM3D_OLD_${_sam3d_var}=${!_sam3d_var}"; fi
    unset "${_sam3d_var}"
done
unset _sam3d_var
export PYTHONNOUSERSITE=1
export CUDA_HOME="${CONDA_PREFIX}"
EOF
cat > "${CONDA_PREFIX}/etc/conda/deactivate.d/sam3d_env.sh" << 'EOF'
unset CUDA_HOME PYTHONNOUSERSITE
for _sam3d_var in PYTHONPATH LD_LIBRARY_PATH LIBRARY_PATH CUDA_HOME; do
    _sam3d_old="_SAM3D_OLD_${_sam3d_var}"
    if [ -n "${!_sam3d_old+x}" ]; then export "${_sam3d_var}=${!_sam3d_old}"; unset "${_sam3d_old}"; fi
done
unset _sam3d_var _sam3d_old
EOF
export CUDA_HOME="${CONDA_PREFIX}"

echo "python: $(which python) ($(python --version))"
echo "nvcc:   $(which nvcc)"
case "$(which python)" in
    "${CONDA_PREFIX}"/bin/python) ;;
    *) echo "ERROR: python is not in ${CONDA_PREFIX}" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Python dependencies
# ---------------------------------------------------------------------------
# pytorch/cuda dependencies
# pypi.ngc.nvidia.com (upstream doc/setup.md) is omitted: it is unresolvable from this network and
# makes pip retry 5 times (--retries default) on every request (see docs/issue.md)
export PIP_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cu128"
# Pin gradio here as well, otherwise MoGe pulls gradio 6.x (+ hf-gradio), which is downgraded
# by '.[inference]' and leaves a dependency conflict (hf-gradio requires gradio-client>=2.0)
python -m pip install -e '.[dev]' "$(grep '^gradio==' requirements.inference.txt)"
python -m pip install -e '.[p3d]'  # pytorch3d dependency on pytorch is broken, 2-step install

# inference dependencies
export PIP_FIND_LINKS="https://nvidia-kaolin.s3.us-east-2.amazonaws.com/torch-2.7.1_cu128.html"
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
if torch.version.cuda != "12.8":
    errors.append(f"torch CUDA version is {torch.version.cuda}, expected 12.8")
if "sm_120" not in torch.cuda.get_arch_list():
    errors.append(f"torch has no sm_120 (Blackwell) kernels: {torch.cuda.get_arch_list()}")
if torch.cuda.is_available():
    # Run actual kernels: "no kernel image is available" only shows up here (see docs/issue.md)
    import pytorch3d.ops, spconv.pytorch, gsplat, kaolin
    x = torch.randn(64, 64, device="cuda")
    (x @ x).sum().item()
    print(f"GPU:    {torch.cuda.get_device_name(0)} (sm_{''.join(map(str, torch.cuda.get_device_capability(0)))}) OK")
else:
    print("WARNING: torch.cuda.is_available() is False (no GPU visible).")
if errors:
    sys.exit("ERROR: " + "\nERROR: ".join(errors))
EOF
if ! nvcc --version | grep -q "release 12.8"; then
    echo "ERROR: nvcc is not CUDA 12.8 ($(which nvcc))." >&2
    exit 1
fi

echo "╚══╣ Setup: SAM 3D Objects (FINISHED) ╠══╝"
