#!/bin/bash
# Build the store node image and, optionally, a bootable ISO.
#
#   ./build.sh                      build the image
#   ./build.sh --push               build and push
#   ./build.sh --push --iso         build, push, then make an installer ISO
#
# Entitlements: on a subscribed RHEL build host, podman injects them
# automatically and nothing else is needed. On an unsubscribed host (a Fedora
# workstation, for example), drop an activation key and org id into:
#
#   bootc/secrets/rhsm-key      bootc/secrets/rhsm-org
#
# Those are gitignored and are mounted as build secrets, so they never land in
# an image layer.

set -euo pipefail
cd "$(dirname "$0")"

REGISTRY=${REGISTRY:-quay.io/your-org}
IMAGE=${IMAGE:-store-node}
TAG=${TAG:-latest}
REF="${REGISTRY}/${IMAGE}:${TAG}"

PUSH=0; ISO=0
for a in "$@"; do
  case "$a" in
    --push) PUSH=1 ;;
    --iso)  ISO=1 ;;
    *) echo "unknown argument: $a"; exit 1 ;;
  esac
done

# --- entitlement handling ---------------------------------------------------
SECRET_ARGS=()
if [ -s secrets/rhsm-key ] && [ -s secrets/rhsm-org ]; then
  echo ">> using activation key from bootc/secrets/"
  SECRET_ARGS=(--secret "id=rhsm-key,src=secrets/rhsm-key"
               --secret "id=rhsm-org,src=secrets/rhsm-org")
elif [ -d /etc/pki/entitlement ] && compgen -G "/etc/pki/entitlement/*.pem" >/dev/null; then
  echo ">> using build-host entitlements (podman injects these automatically)"
  # No secrets passed; the Containerfile marks them required=false.
else
  cat <<'EOF'
!! No RHEL entitlement available.

   Either build on a subscribed RHEL host, or create:
     bootc/secrets/rhsm-key   containing an activation key
     bootc/secrets/rhsm-org   containing your org id
   from https://console.redhat.com/insights/connector/activation-keys
EOF
  exit 1
fi

# --- registry auth ----------------------------------------------------------
# Fail here with something actionable rather than part-way through a pull.
BASE_REGISTRY=registry.redhat.io
if ! podman login --get-login "${BASE_REGISTRY}" >/dev/null 2>&1; then
  cat <<EOF
!! Not logged in to ${BASE_REGISTRY} — the base image cannot be pulled.

   Run:  podman login ${BASE_REGISTRY}

   Use your Red Hat account, or a registry service account token from
   https://access.redhat.com/terms-based-registry/
EOF
  exit 1
fi

if [ "$PUSH" = 1 ]; then
  PUSH_REGISTRY="${REGISTRY%%/*}"
  if ! podman login --get-login "${PUSH_REGISTRY}" >/dev/null 2>&1; then
    echo "!! Not logged in to ${PUSH_REGISTRY} — run: podman login ${PUSH_REGISTRY}"
    exit 1
  fi
fi

# --- build ------------------------------------------------------------------
echo ">> building ${REF}"
podman build "${SECRET_ARGS[@]}" -t "${REF}" -f Containerfile .

echo ">> image built:"
podman images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | grep "${IMAGE}" || true

# Confirm the DRBD module actually made it in — the most likely thing to break
# when the base image's kernel moves.
echo ">> verifying DRBD kernel module against the image kernel"
podman run --rm "${REF}" bash -c '
  k=$(rpm -q kernel --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n" | tail -1)
  echo "   kernel in image : $k"
  if find /lib/modules -name "drbd.ko*" | grep -q .; then
    echo "   drbd module     : $(find /lib/modules -name "drbd.ko*" | head -1)"
  else
    echo "   drbd module     : MISSING — kmod-drbd9x does not match this kernel"
    exit 1
  fi'

# --- push -------------------------------------------------------------------
if [ "$PUSH" = 1 ]; then
  echo ">> pushing ${REF}"
  podman push "${REF}"
fi

# --- iso --------------------------------------------------------------------
if [ "$ISO" = 1 ]; then
  grep -q 'PASTE-YOUR-SSH-PUBLIC-KEY-HERE' config.toml && {
    echo "!! set your SSH public key in bootc/config.toml first"; exit 1; }

  # Without --push the image only exists in local container storage, so tell
  # the builder to read it from there rather than trying to pull it. No
  # registry is needed just to produce installation media.
  LOCAL_ARG=()
  [ "$PUSH" = 1 ] || LOCAL_ARG=(--local)

  mkdir -p output
  echo ">> building installer ISO"
  sudo podman run --rm -it --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v "$(pwd)/config.toml:/config.toml:ro" \
    -v "$(pwd)/output:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    registry.redhat.io/rhel9/bootc-image-builder:latest \
    --type iso \
    --config /config.toml \
    "${LOCAL_ARG[@]}" \
    "${REF}"

  echo ">> ISO written to:"
  find output -name '*.iso' -printf '   %p  (%s bytes)\n'
fi

cat <<EOF

Next:
  1. Write the ISO to USB and install BOTH nodes from it.
     One image, both nodes — identity comes from Ansible, not the image.
     Afterwards check what the installer chose:  cat /root/disk-layout.log
  2. Put the nodes' DHCP addresses in inventory/lab.yml, then:
       ansible-playbook playbooks/01-discover.yml     # writes host_vars
  3. ansible-playbook playbooks/00-substrate.yml -e fence_backend=redfish

To update a running node later:
       ssh root@<node> 'bootc upgrade && systemctl reboot'
EOF
