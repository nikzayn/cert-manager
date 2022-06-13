#!/usr/bin/env bash

# Copyright 2020 The cert-manager Authors.
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

set -o nounset
set -o errexit
set -o pipefail

LIB_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" > /dev/null && pwd )"
export REPO_ROOT="$LIB_ROOT/../.."

export SKIP_BUILD_ADDON_IMAGES="${SKIP_BUILD_ADDON_IMAGES:-}"
export KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind}"
# Default Kubernetes version to use to 1.24
export K8S_VERSION=${K8S_VERSION:-1.24}
# Default OpenShift version to use to 3.11
export OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-"3.11"}
export IS_OPENSHIFT="${IS_OPENSHIFT:-"false"}"
export OPENSHIFT_VERSION="${OPENSHIFT_VERSION:-"3.11"}"
# kubectl cluster-info dump does not return output in format that could be
# easily parsed with a json or yaml parser.
export SERVICE_IP_PREFIX=$(kubectl cluster-info dump | grep ip-range | head -n1 | cut -d= -f2 | cut -d. -f1,2,3)
export DNS_SERVER="${SERVICE_IP_PREFIX}.16"
export INGRESS_IP="${SERVICE_IP_PREFIX}.15"
export GATEWAY_IP="${SERVICE_IP_PREFIX}.14"

# setup_tools will build and set up the environment to use bazel-provided
# versions of the tools required for development
setup_tools() {
  check_bazel
  bazel build //hack/bin:helm //hack/bin:kind //hack/bin:kubectl //devel/bin:ginkgo
  if [[ "$IS_OPENSHIFT" == "true" ]] ; then
    bazel build //hack/bin:oc3
  fi
  local bindir="$(bazel info bazel-genfiles)"
  export HELM="${bindir}/hack/bin/helm"
  export KIND="${bindir}/hack/bin/kind"
  export OC3="${bindir}/hack/bin/oc3"
  export KUBECTL="${bindir}/hack/bin/kubectl"
  export KUSTOMIZE="${bindir}/hack/bin/kustomize"
  export GINKGO="${bindir}/devel/bin/ginkgo"
  # Configure PATH to use bazel provided e2e tools
  export PATH="${SCRIPT_ROOT}/bin:$PATH"
}

# check_tool ensures that the tool with the given name is available, or advises
# users to setup their PATH for the circleci.dec.yaml/e3e/bin directory if not.
check_tool() {
  tool="$1"
  if ! command -v "$tool" &>/dev/null; then
    echo "Fatal error: $tool not found. Install $tool or run: export PATH=\"$REPO_ROOT/devel/bin:\$PATH\"" >&2
    exit 1
  fi
}

# check_bazel ensures that bazel is installed/available.
check_bazel() {
  if ! command -v bazel &>/dev/null; then
    echo "Install bazel at https://bazel.build" >&2
    exit 1
  fi
}

# require_image will attempt to ensure that the named docker image exists
# within the kind cluster with name $KIND_CLUSTER_NAME.
# If $SKIP_BUILD_ADDON_IMAGES is 'true', the image will not be built and a
# warning message will be printed instead.
require_image() {
  IMAGE_NAME="$1"
  BAZEL_TARGET="$2"
  # Skip building and loading the image if SKIP_BUILD_ADDON_IMAGES=true
  if [ "${SKIP_BUILD_ADDON_IMAGES:-}" == "true" ]; then
    echo "Skipping building and loading image '$IMAGE_NAME' because SKIP_BUILD_ADDON_IMAGES=true"
    return
  fi

  # Ensure bazel is available
  check_bazel
  # Ensure kind is available
  check_tool kind

  # Build and export the docker image
  bazel run --platforms=@io_bazel_rules_go//go/toolchain:linux_amd64 "${BAZEL_TARGET}"

  # Load the image into the kind cluster
  load_image "$IMAGE_NAME"
}

# load_image will load an image into the local cluster
# for a kind cluster it will load it into the cluster
# with name $KIND_CLUSTER_NAME
load_image() {
  IMAGE_NAME="$1"
  if [[ "$IS_OPENSHIFT" == "true" ]] ; then
    # No loading into a cluster for OpenShift is needed
    # as OpenShift shares the Docker daemon the image was
    # built with
    return
  fi
  kind load docker-image --name "$KIND_CLUSTER_NAME" "$IMAGE_NAME"
}

export_logs() {
  echo "Exporting cluster logs to artifacts..."
  "${SCRIPT_ROOT}/cluster/export-logs.sh"
}

# join_by joins a list of strings by a string.
# e.g. `join_by , a b c` -> `a,b,c`
join_by() {
  local d=${1-} f=${2-}
  if shift 2; then
    printf %s "$f" "${@/#/$d}"
  fi
}

# registered_feature_gates_for returns the subset of supported of feature gates
# from the given enabled features. Supported features is the first argument,
# features that are enabled is second.
registered_feature_gates_for() {
  declare -a FEATURE_GATES_SUPPORTED=($1)
  FEATURE_GATES="$2"
  declare -a FEATURE_GATES_TO_RUN=()
  for val in ${FEATURE_GATES//,/ }; do
    if [[ "${FEATURE_GATES_SUPPORTED[*]}" =~ "${val%=*}" ]]; then
      FEATURE_GATES_TO_RUN+=($val)
    fi
  done
  join_by , ${FEATURE_GATES_TO_RUN[@]}
}
