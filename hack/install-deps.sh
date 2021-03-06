#!/bin/bash

# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Dependencies:
# runc:
# - libseccomp-dev(Ubuntu,Debian)/libseccomp-devel(Fedora, CentOS, RHEL). Note that
# libseccomp in ubuntu <=trusty and debian <=jessie is not new enough, backport
# is required.
# - libapparmor-dev(Ubuntu,Debian)/libapparmor-devel(Fedora, CentOS, RHEL)
# containerd:
# - btrfs-tools(Ubuntu,Debian)/btrfs-progs-devel(Fedora, CentOS, RHEL)

set -o errexit
set -o nounset
set -o pipefail

source $(dirname "${BASH_SOURCE[0]}")/utils.sh

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/..
. ${ROOT}/hack/versions

# DESTDIR is the dest path to install dependencies.
DESTDIR=${DESTDIR:-"/"}
# Convert to absolute path if it's relative.
if [[ ${DESTDIR} != /* ]]; then
  DESTDIR=${ROOT}/${DESTDIR}
fi

# NOSUDO indicates not to use sudo during installation.
NOSUDO=${NOSUDO:-false}
sudo="sudo"
if ${NOSUDO}; then
  sudo=""
fi

# INSTALL_CNI indicates whether to install CNI. CNI installation
# makes sense for local testing, but doesn't make sense for cluster
# setup, because CNI daemonset is usually used to deploy CNI binaries
# and configurations in cluster.
INSTALL_CNI=${INSTALL_CNI:-true}

# COOK_CONTAINERD indicates whether to update containerd with newest
# cri plugin before install. This is mainly used for testing new cri
# plugin change.
COOK_CONTAINERD=${COOK_CONTAINERD:-false}

CONTAINERD_DIR=${DESTDIR}/usr/local
RUNC_DIR=${DESTDIR}
CNI_DIR=${DESTDIR}/opt/cni
CNI_CONFIG_DIR=${DESTDIR}/etc/cni/net.d
CRICTL_DIR=${DESTDIR}/usr/local/bin
CRICTL_CONFIG_DIR=${DESTDIR}/etc

RUNC_PKG=github.com/opencontainers/runc
CNI_PKG=github.com/containernetworking/plugins
CONTAINERD_PKG=github.com/containerd/containerd
CRITOOL_PKG=github.com/kubernetes-incubator/cri-tools
CRI_CONTAINERD_PKG=github.com/containerd/cri-containerd

# Create a temporary GOPATH for make install.deps.
TMPGOPATH=$(mktemp -d /tmp/cri-containerd-install-deps.XXXX)
GOPATH=${TMPGOPATH}

# checkout_repo checks out specified repository
# and switch to specified  version.
# Varset:
# 1) Pkg name;
# 2) Version;
# 3) Repo name;
checkout_repo() {
  local -r pkg=$1
  local -r version=$2
  local -r repo=$3
  path="${GOPATH}/src/${pkg}"
  if [ ! -d ${path} ]; then
    mkdir -p ${path}
    git clone https://${repo} ${path}
  fi
  cd ${path}
  git fetch --all
  git checkout ${version}
}

# Install runc
checkout_repo ${RUNC_PKG} ${RUNC_VERSION} ${RUNC_REPO}
cd ${GOPATH}/src/${RUNC_PKG}
BUILDTAGS=${BUILDTAGS:-seccomp apparmor}
make static BUILDTAGS="$BUILDTAGS"
${sudo} make install -e DESTDIR=${RUNC_DIR}

# Install cni
if ${INSTALL_CNI}; then
  checkout_repo ${CNI_PKG} ${CNI_VERSION} ${CNI_REPO}
  cd ${GOPATH}/src/${CNI_PKG}
  ./build.sh
  ${sudo} mkdir -p ${CNI_DIR}
  ${sudo} cp -r ./bin ${CNI_DIR}
  ${sudo} mkdir -p ${CNI_CONFIG_DIR}
  ${sudo} bash -c 'cat >'${CNI_CONFIG_DIR}'/10-containerd-net.conflist <<EOF
{
  "cniVersion": "0.3.1",
  "name": "containerd-net",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "ipam": {
        "type": "host-local",
        "subnet": "10.88.0.0/16",
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    }
  ]
}
EOF'
fi

# Install containerd
checkout_repo ${CONTAINERD_PKG} ${CONTAINERD_VERSION} ${CONTAINERD_REPO}
cd ${GOPATH}/src/${CONTAINERD_PKG}
if ${COOK_CONTAINERD}; then
  # Verify that vendor.conf is in sync with containerd before cook containerd,
  # this is a hard requirement.
  if ! ${ROOT}/hack/update-vendor.sh -only-verify; then
    echo "Please run hack/update-vendor.sh before cook containerd."
    exit 1
  fi
  # Import cri plugin into containerd.
  # TODO(random-liu): Remove this after containerd starts to vendor cri plugin.
  echo "import _ \"${CRI_CONTAINERD_PKG}\"" >> cmd/containerd/builtins_linux.go
  # 1. Copy all cri-containerd vendors into containerd vendor. This makes sure
  # all dependencies introduced by cri-containerd will be updated. There might
  # be unnecessary vendors introduced, but it still builds.
  cp -rT ${ROOT}/vendor/ vendor/
  # 2. Remove containerd repo itself from vendor.
  rm -rf vendor/${CONTAINERD_PKG}
  # 3. Create cri-containerd vendor in containerd vendor, and copy the newest
  # cri-containerd there.
  if [ -d "vendor/${CRI_CONTAINERD_PKG}" ]; then
    rm -rf vendor/${CRI_CONTAINERD_PKG}/*
  else
    mkdir -p vendor/${CRI_CONTAINERD_PKG}
  fi
  cp -rT ${ROOT} vendor/${CRI_CONTAINERD_PKG}
  # 4. Remove the extra vendor in cri-containerd.
  rm -rf vendor/${CRI_CONTAINERD_PKG}/vendor
  # After the 4 steps above done, we have a containerd with newest cri-containerd
  # plugin.
fi
make BUILDTAGS="${BUILDTAGS}"
# containerd make install requires `go` to work. Explicitly
# set PATH to make sure it can find `go` even with `sudo`.
${sudo} sh -c "PATH=${PATH} make install -e DESTDIR=${CONTAINERD_DIR}"

#Install crictl
checkout_repo ${CRITOOL_PKG} ${CRITOOL_VERSION} ${CRITOOL_REPO}
cd ${GOPATH}/src/${CRITOOL_PKG}
make crictl
${sudo} make install-crictl -e BINDIR=${CRICTL_DIR} GOPATH=${GOPATH}
${sudo} mkdir -p ${CRICTL_CONFIG_DIR}
${sudo} bash -c 'cat >'${CRICTL_CONFIG_DIR}'/crictl.yaml <<EOF
runtime-endpoint: /var/run/cri-containerd.sock
EOF'

# Clean the tmp GOPATH dir. Use sudo because runc build generates
# some privileged files.
${sudo} rm -rf ${TMPGOPATH}
