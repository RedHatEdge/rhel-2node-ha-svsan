# Two-node store platform — control node tasks.
#
#   make venv        create .venv and install pinned deps + collections
#   make ping        connectivity check against the inventory
#   make discover    gather hardware, write inventory/host_vars
#   make substrate   cluster, quorum, fencing, KVM  (both options need this)
#   make drbd        stage Option B
#   make svsan       stage Option A
#   make status      pcs status from node1
#
# Everything runs inside .venv, so the system Ansible is never used.

VENV    := .venv
ANSIBLE := $(VENV)/bin/ansible
PLAYBOOK:= $(VENV)/bin/ansible-playbook
GALAXY  := $(VENV)/bin/ansible-galaxy
FENCE   ?= redfish

.PHONY: venv lock ping discover substrate drbd svsan status test clean

venv: $(VENV)/.stamp
$(VENV)/.stamp: requirements.txt requirements.yml
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet --upgrade pip
	$(VENV)/bin/pip install --quiet -r requirements.txt
	$(GALAXY) collection install -r requirements.yml -p ./collections --force
	@touch $@
	@echo
	@$(ANSIBLE) --version | head -2
	@echo "ready — run 'make ping'"

lock: venv
	@$(VENV)/bin/pip freeze > requirements.lock
	@$(GALAXY) collection list -p ./collections 2>/dev/null | grep -E '^[a-z]' > collections.lock || true
	@echo "wrote requirements.lock and collections.lock"

ping: venv
	$(ANSIBLE) all -m ping

discover: venv
	$(PLAYBOOK) playbooks/01-discover.yml

substrate: venv
	$(PLAYBOOK) playbooks/00-substrate.yml -e fence_backend=$(FENCE)

svsan: venv
	$(PLAYBOOK) playbooks/10-storage-svsan.yml -e storage_backend=svsan -e svsan_attach_san_nic=false

status: venv
	@$(ANSIBLE) node1 -a 'pcs status' 2>/dev/null || echo "cluster not formed yet"

test:
	tests/run-matrix.sh

clean:
	rm -rf $(VENV) collections

# ── Option A: appliance image ──────────────────────────────────────────────
# Converts the Hyper-V package to a KVM boot image. Uses the Hyper-V VHD rather
# than the vSphere OVA: the two disks are byte-identical, but the OVA declares
# transport com.vmware.guestInfo and ships no CD-ROM, so it expects config over
# the VMware Tools channel that KVM does not have.
#
#   make vsa-image ZIP=~/Downloads/svsan_6-7_windows_installer_plus_powershell.zip
vsa-image:
	@test -n "$(ZIP)" || { echo "usage: make vsa-image ZIP=<windows_installer zip>"; exit 1; }
	@mkdir -p lab/svsan/images
	@tmp=$$(mktemp -d) && \
	  unzip -oq "$(ZIP)" StorMagicSvSAN.msi -d $$tmp && \
	  7z x -y -o$$tmp $$tmp/StorMagicSvSAN.msi VSA.zip >/dev/null && \
	  unzip -oq $$tmp/VSA.zip -d $$tmp && \
	  qemu-img convert -O qcow2 "$$tmp/VSA/Virtual Hard Disks/VSA.vhd" \
	    lab/svsan/images/svsan-vsa.qcow2 && \
	  rm -rf $$tmp && \
	  echo "appliance image -> lab/svsan/images/svsan-vsa.qcow2"

# Snapshot ACTIVATED appliances so a rebuild keeps its licence.
#
# TAKE THIS IMMEDIATELY AFTER THE WIZARD, BEFORE CREATING ANY POOL OR TARGET.
# The useful restore point is activated-but-empty. A snapshot taken after a
# mirror exists carries that mirror's metadata, so restoring it reinstates a
# target whose backing store is gone — and an orphaned mirrored target cannot be
# deleted through the UI or the API. That mistake cost an afternoon on 19 August
# and was only escapable by destroying both appliances. The licence is
# bound to the serial, the serial is derived from the pinned MAC, so a snapshot
# taken after activation restores licensed with no key spent.
#   make vsa-snapshot
vsa-snapshot: venv
	@mkdir -p lab/svsan/images
	@for n in node1 node2; do \
	  ip=$$($(VENV)/bin/ansible-inventory -i inventory --host $$n 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["lan_ip"])'); \
	  echo "snapshotting svsan-$$n from $$ip"; \
	  ssh -o BatchMode=yes root@$$ip "virsh shutdown svsan-$$n >/dev/null 2>&1; sleep 20; \
	    qemu-img convert -O qcow2 /var/lib/libvirt/images/svsan-$$n-boot.qcow2 /tmp/snap.qcow2" && \
	  scp -q root@$$ip:/tmp/snap.qcow2 lab/svsan/images/svsan-$$n-boot.qcow2 && \
	  ssh -o BatchMode=yes root@$$ip "rm -f /tmp/snap.qcow2; virsh start svsan-$$n >/dev/null 2>&1" && \
	  echo "  -> lab/svsan/images/svsan-$$n-boot.qcow2"; \
	done

# Tear Option A down completely, leaving Option B untouched.
vsa-destroy: venv
	$(VENV)/bin/ansible cluster -i inventory -b -m shell -a '\
	  virsh destroy svsan-$$(hostname -s) 2>/dev/null; \
	  virsh undefine svsan-$$(hostname -s) 2>/dev/null; \
	  rm -f /var/lib/libvirt/images/svsan-$$(hostname -s)-*.qcow2; \
	  lvremove -f vgstore/lv-svsan-pool 2>/dev/null; true'
	@echo "Option A removed. Option B (DRBD) untouched."

# ── Option A: witness container ────────────────────────────────────────────
# The SvSAN witness as a container, deployable to any RHEL 9 host with podman.
# StorMagic ship it only as an armhf .deb and a vSphere appliance; the amd64
# binaries are lifted from their own vCenter plugin appliance.
#
#   make nsh-image ZIP=~/Downloads/svsan_6-7_plugin_ova.zip
nsh-image:
	@test -n "$(ZIP)" || { echo "usage: make nsh-image ZIP=<plugin_ova zip>"; exit 1; }
	containers/nsh-witness/extract-nsh.sh "$(ZIP)"
	podman build -t localhost/nsh-witness:6.7.0.3 containers/nsh-witness
	@mkdir -p lab/svsan/images
	podman save -o lab/svsan/images/nsh-witness.tar localhost/nsh-witness:6.7.0.3
	@echo "witness image -> lab/svsan/images/nsh-witness.tar"

# Deploy just the witness, without touching the rest of Option A.
witness: venv
	$(VENV)/bin/ansible-playbook -i inventory playbooks/10-storage-svsan.yml \
	  -e storage_backend=svsan --limit arbiter

# Attach the storage NIC once the VSAs are licensed. Deliberately a separate
# step: a pristine appliance DHCPs on every interface, so a storage segment that
# serves DHCP can give it a second default route and break activation.
svsan-attach-san: venv
	$(VENV)/bin/ansible-playbook -i inventory playbooks/10-storage-svsan.yml \
	  -e storage_backend=svsan -e svsan_attach_san_nic=true --limit cluster

# Rebuild the pool volume from scratch, wiping any previous pool signature.
# The recovery path when a target has been orphaned.
svsan-wipe-pool: venv
	$(VENV)/bin/ansible-playbook -i inventory playbooks/10-storage-svsan.yml \
	  -e storage_backend=svsan -e svsan_pool_wipe=true --limit cluster

# Regenerate architecture diagrams from the source page.
# The HTML page is the source of truth; the SVGs are extracted from it.
diagrams:
	@python3 -c "\
import re,pathlib; \
h=pathlib.Path('docs/diagrams/svsan-architecture.html').read_text(); \
svgs=re.findall(r'(<svg viewBox=\"([^\"]+)\".*?</svg>)',h,flags=re.S); \
[ (lambda b,vb,n: pathlib.Path('docs/diagrams/%s.svg'%n).write_text( \
  '<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n' + \
  re.sub(r'<!--(.*?)-->', lambda m: '<!-- '+re.sub(r'-{2,}',' ',m.group(1)).strip()+' -->', \
    b.replace('<svg viewBox=','<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox='%(vb.split()[2],vb.split()[3]),1) \
     .replace('>','><rect width=\"%s\" height=\"%s\" fill=\"#ffffff\"/>'%(vb.split()[2],vb.split()[3]),1), flags=re.S)+'\n'))(b,vb,n) \
  for (b,vb),n in zip(svgs,['svsan-architecture','svsan-quorum'])]"
	@for f in svsan-architecture svsan-quorum; do \
	  inkscape docs/diagrams/$$f.svg --export-type=png --export-filename=docs/diagrams/$$f.png --export-dpi=192 >/dev/null 2>&1; \
	  inkscape docs/diagrams/$$f.svg --export-type=pdf --export-filename=docs/diagrams/$$f.pdf >/dev/null 2>&1; \
	  echo "  docs/diagrams/$$f.{svg,png,pdf}"; \
	done

# Log the hosts in to the mirrored target and verify multipath.
# Requires the host IQNs to be in the target's ACL on the VSA first.
svsan-attach: venv
	$(VENV)/bin/ansible-playbook -i inventory playbooks/11-present-targets.yml \
	  -e storage_backend=svsan

# Build the POS and Postgres guests on whichever storage backend is active.
guests: venv
	$(VENV)/bin/ansible-playbook -i inventory playbooks/30-guests.yml \
	  -e storage_backend=$(or $(BACKEND),svsan)

# Apply iSCSI/multipath failover timing and rebuild sessions so it takes effect.
svsan-tune: venv
	$(VENV)/bin/ansible-playbook -i inventory playbooks/12-failover-tuning.yml \
	  -e storage_backend=svsan
