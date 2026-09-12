#!/usr/bin/env bash
# Run unprivileged on Ubuntu. Download only; never execute downloaded code here.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source_dir=$PWD
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || exit 1
mkdir -p downloads
curl --proto '=https' --tlsv1.2 -fLsS --retry 3 --max-time 300 \
  'https://github.com/k3s-io/k3s/releases/download/v1.36.4%2Bk3s1/k3s' -o downloads/k3s
curl --proto '=https' --tlsv1.2 -fLsS --retry 3 --max-time 60 \
  'https://raw.githubusercontent.com/k3s-io/k3s/v1.36.4%2Bk3s1/install.sh' -o downloads/install.sh
(cd downloads && sha256sum --check "$source_dir/SHA256SUMS")
echo 'Pinned K3s v1.36.4+k3s1 downloaded and verified. Nothing installed.'
