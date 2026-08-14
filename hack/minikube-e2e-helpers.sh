#!/usr/bin/env bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0
#
# Helper functions for minikube-based e2e CI.
# Source this file: source hack/minikube-e2e-helpers.sh

set -euo pipefail

ts() { date +%H:%M:%S; }

# Apply minikube-specific kustomization patches.
# These are needed because minikube docker driver uses loopback-backed
# LVM for OSD storage and doesn't have real block devices.
patch_kustomize_for_minikube() {
    local cluster_kust="test/drenv/addons/rook/cluster/kustomization.yaml"
    local operator_kust="test/drenv/addons/rook/operator/kustomization.yaml"

    # Apply kustomize patches using python for reliable YAML manipulation.
    python3 - "$operator_kust" "$cluster_kust" <<'PYEOF'
import sys, yaml

op_file, cl_file = sys.argv[1], sys.argv[2]

# Operator: allow loop devices in ConfigMap JSON patch.
with open(op_file) as f:
    doc = yaml.safe_load(f)
for p in doc["patches"]:
    if p.get("target", {}).get("kind") == "ConfigMap":
        ops = yaml.safe_load(p["patch"])
        ops.append({"op": "add", "path": "/data/ROOK_CEPH_ALLOW_LOOP_DEVICES", "value": "true"})
        p["patch"] = yaml.dump(ops, default_flow_style=False)
        break
with open(op_file, "w") as f:
    yaml.dump(doc, f, default_flow_style=False, sort_keys=False)

# Cluster: PVC-backed OSDs.
with open(cl_file) as f:
    doc = yaml.safe_load(f)
for p in doc["patches"]:
    if p.get("target", {}).get("kind") == "CephCluster":
        ops = yaml.safe_load(p["patch"])
        ops.extend([
            {"op": "replace", "path": "/spec/storage/useAllNodes", "value": False},
            {"op": "replace", "path": "/spec/storage/useAllDevices", "value": False},
            {"op": "add", "path": "/spec/storage/storageClassDeviceSets", "value": [{
                "name": "ceph-osd", "count": 1, "portable": False, "tuneDeviceClass": False,
                "volumeClaimTemplates": [{"metadata": {"name": "data"}, "spec": {
                    "resources": {"requests": {"storage": "5Gi"}},
                    "storageClassName": "ceph-block-local",
                    "volumeMode": "Block", "accessModes": ["ReadWriteOnce"]}}]}]},
        ])
        p["patch"] = yaml.dump(ops, default_flow_style=False)
        break
with open(cl_file, "w") as f:
    yaml.dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF

    # Use rbd-nbd instead of krbd. Docker-driver minikube clusters share the
    # host kernel, so krbd's /sys/bus/rbd/devices/ is global across containers.
    # During failover the target cluster reuses the source's rbd mapping,
    # causing permanent EBUSY on unmap. rbd-nbd runs in userspace per
    # container, avoiding the shared-kernel device namespace entirely.
    sed -i '/csi.storage.k8s.io\/fstype: ext4/a\    mounter: rbd-nbd' \
        test/drenv/addons/rook/pool/storage-class.yaml

    echo "[$(ts)] Kustomization patches applied for minikube"
}

# Set up LVM-backed Ceph OSD disk and local PV on a minikube profile.
setup_osd_disk() {
    local profile=$1
    echo "[$(ts)] Setting up OSD disk on $profile"
    docker exec "$profile" bash -c "
        set -euo pipefail
        apt-get update -qq && apt-get install -y -qq lvm2 >/dev/null
        truncate -s 5G /data/ceph-osd.img
        LOOP=\$(losetup --find --show /data/ceph-osd.img)
        pvcreate --yes \"\$LOOP\" >/dev/null
        vgcreate ceph-vg-${profile} \"\$LOOP\" >/dev/null
        lvcreate -l 100%FREE -n ceph-lv ceph-vg-${profile} --yes --zero n >/dev/null
        DMDEV=\$(dmsetup info --noheadings -c -o blkdevname ceph--vg--${profile}-ceph--lv)
        MAJOR=\$(dmsetup info --noheadings -c -o major ceph--vg--${profile}-ceph--lv)
        MINOR=\$(dmsetup info --noheadings -c -o minor ceph--vg--${profile}-ceph--lv)
        mknod /dev/\$DMDEV b \$MAJOR \$MINOR 2>/dev/null || true
        mkdir -p /dev/mapper /dev/ceph-vg-${profile}
        ln -sf /dev/\$DMDEV /dev/mapper/ceph--vg--${profile}-ceph--lv
        ln -sf /dev/\$DMDEV /dev/ceph-vg-${profile}/ceph-lv
        echo \"Device: /dev/\$DMDEV (\$MAJOR:\$MINOR)\"
    "
    kubectl --context "$profile" apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-block-local
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ceph-osd-pv
spec:
  capacity:
    storage: 5Gi
  volumeMode: Block
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ceph-block-local
  local:
    path: /dev/ceph-vg-${profile}/ceph-lv
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${profile}
EOF
    echo "[$(ts)] OSD disk + local PV created for $profile"
}

# Create nbd device nodes inside a minikube container.
# Docker containers don't have devtmpfs so host /dev/nbd* aren't visible.
# rbd-nbd needs these nodes to map RBD images as block devices.
create_nbd_devices() {
    local profile=$1
    local major
    major=$(grep ' nbd$' /proc/devices | awk '{print $1}')
    if [ -z "$major" ]; then
        echo "[$(ts)] WARNING: nbd module not loaded, skipping nbd device creation"
        return
    fi
    docker exec "$profile" bash -c "
        for i in \$(seq 0 15); do
            mknod -m 0660 /dev/nbd\$i b $major \$i 2>/dev/null || true
        done
    "
    echo "[$(ts)] Created nbd devices in $profile (major=$major)"
}

# Copy host udev data into a minikube container.
copy_udev_data() {
    local profile=$1
    tar -C /run/udev -cf - data \
        | docker exec -i "$profile" sh -c 'mkdir -p /run/udev && tar -C /run/udev -xf -'
}

# Pull Ceph images directly into minikube containerd (skip host docker).
pull_ceph_images() {
    local images=(
        quay.io/ceph/ceph:v20.2.0
        docker.io/rook/ceph:v1.19.7
        quay.io/cephcsi/cephcsi:v3.16.2
        quay.io/nladha/csiaddons-sidecar:cg
    )
    echo "[$(ts)] Pulling images into minikube containerd..."
    local pids=()
    for profile in dr1 dr2; do
        for img in "${images[@]}"; do
            (ok=0
            for attempt in 1 2 3; do
                if docker exec "$profile" crictl pull "$img"; then ok=1; break; fi
                echo "[$(date +%H:%M:%S)] Retry $attempt: $img on $profile" >&2
                sleep 3
            done
            [ "$ok" -eq 1 ]) &
            pids+=($!)
        done
    done
    local failed=0
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
    if [ "$failed" -eq 1 ]; then
        echo "[$(ts)] ERROR: Some image pulls failed"
        return 1
    fi
    echo "[$(ts)] All images pulled"
}

# Install CRDs required by ramen that are not part of the base cluster.
install_extra_crds() {
    local profile=$1

    # VolumeGroupSnapshot CRDs (openshift.io group, sed from k8s.io).
    local rhs_tag="v8.2.1"
    local rhs_base="https://raw.githubusercontent.com/red-hat-storage/external-snapshotter/${rhs_tag}/client/config/crd"
    for crd in \
        groupsnapshot.storage.k8s.io_volumegroupsnapshotclasses.yaml \
        groupsnapshot.storage.k8s.io_volumegroupsnapshotcontents.yaml \
        groupsnapshot.storage.k8s.io_volumegroupsnapshots.yaml; do
        curl -fsSL "${rhs_base}/${crd}" \
            | sed 's/groupsnapshot\.storage\.k8s\.io/groupsnapshot.storage.openshift.io/g' \
            | kubectl --context "$profile" apply -f -
    done

    # VolSync CRDs.
    local volsync_base="https://raw.githubusercontent.com/backube/volsync/v0.16.0/config/crd/bases"
    for crd in volsync.backube_replicationsources.yaml volsync.backube_replicationdestinations.yaml; do
        curl -fsSL "${volsync_base}/${crd}" | kubectl --context "$profile" apply -f -
    done
}

# Restart all Submariner data-path pods to refresh VXLAN tunnel and
# service discovery state. On docker-driver minikube (shared kernel),
# globalnet iptables rules and Lighthouse DNS cache degrade over time.
refresh_submariner_tunnel() {
    echo "[$(ts)] Refreshing Submariner data path (gateway + lighthouse restart)..."

    for profile in dr1 dr2; do
        for app in submariner-gateway submariner-routeagent submariner-lighthouse-agent submariner-lighthouse-coredns; do
            kubectl --context "$profile" -n submariner-operator delete pods -l app="$app" --wait=false 2>/dev/null || true
        done
    done
    # Wait for old pods to terminate before checking for new ones
    sleep 5
    for profile in dr1 dr2; do
        kubectl --context "$profile" -n submariner-operator wait pod \
            -l app=submariner-gateway --for=condition=Ready --timeout=120s 2>/dev/null || true
        kubectl --context "$profile" -n submariner-operator rollout status \
            deploy/submariner-lighthouse-agent --timeout=120s 2>/dev/null || true
        kubectl --context "$profile" -n submariner-operator rollout status \
            deploy/submariner-lighthouse-coredns --timeout=120s 2>/dev/null || true
    done
    for i in $(seq 1 24); do
        if subctl show connections --context dr1 2>&1 | grep -q "connected"; then
            echo "[$(ts)] Submariner tunnel re-established after restart"
            return 0
        fi
        echo "[$(ts)] Waiting for tunnel re-establishment ($i/24)..."
        sleep 5
    done
    echo "[$(ts)] WARNING: tunnel not connected after restart"
    subctl show all --context dr1 2>&1 || true
    return 1
}

# Collect debug info for a cluster profile.
collect_debug() {
    local profile=$1
    echo "======== $profile ========"

    echo "--- PV/PVC ---"
    kubectl --context "$profile" get pv,pvc -A 2>/dev/null || true

    echo "--- StorageClass ---"
    kubectl --context "$profile" get sc 2>/dev/null || true

    echo "--- CephCluster status ---"
    kubectl --context "$profile" -n rook-ceph get cephcluster -o yaml 2>/dev/null \
        | grep -A20 'status:' | head -30 || true

    echo "--- All rook-ceph pods ---"
    kubectl --context "$profile" -n rook-ceph get pods -o wide 2>/dev/null || true

    echo "--- Ramen operator pods ---"
    kubectl --context "$profile" -n ramen-system get pods -o wide 2>/dev/null || true

    echo "--- Ramen hub operator logs (last 30) ---"
    kubectl --context "$profile" -n ramen-system logs deploy/ramen-hub-operator --tail=30 2>/dev/null || true

    echo "--- Ramen dr-cluster operator logs (last 30) ---"
    kubectl --context "$profile" -n ramen-system logs deploy/ramen-dr-cluster-operator --tail=30 2>/dev/null || true

    echo "--- CSI RBD plugin logs (last 30) ---"
    kubectl --context "$profile" -n rook-ceph logs -l app=csi-rbdplugin -c csi-rbdplugin --tail=30 2>/dev/null || true

    echo "--- E2E workload pods ---"
    for ns in $(kubectl --context "$profile" get ns -o name 2>/dev/null | grep test-disapp); do
        nsname=${ns#namespace/}
        echo "Namespace: $nsname"
        kubectl --context "$profile" -n "$nsname" get pods,pvc -o wide 2>/dev/null || true
        kubectl --context "$profile" -n "$nsname" describe pod -l app=busybox 2>/dev/null | grep -A5 'Events:' || true
    done

    echo "--- VRG status ---"
    kubectl --context "$profile" -n ramen-ops get vrg -o wide 2>/dev/null || true

    echo "--- DRPC status ---"
    kubectl --context "$profile" -n ramen-ops get drpc -o wide 2>/dev/null || true

    echo "--- Submariner pods ---"
    kubectl --context "$profile" -n submariner-operator get pods -o wide 2>/dev/null || true

    echo "--- Submariner gateway logs (last 30) ---"
    kubectl --context "$profile" -n submariner-operator logs -l app=submariner-gateway --tail=30 2>/dev/null || true

    echo "--- VolSync pods ---"
    kubectl --context "$profile" -n volsync-system get pods -o wide 2>/dev/null || true

    echo "--- VolSync ReplicationSource/Destination ---"
    for ns in $(kubectl --context "$profile" get ns -o name 2>/dev/null | grep test-disapp); do
        nsname=${ns#namespace/}
        kubectl --context "$profile" -n "$nsname" get replicationdestinations,replicationsources -o wide 2>/dev/null || true
    done

    echo "--- VolSync controller logs (last 30) ---"
    kubectl --context "$profile" -n volsync-system logs deploy/volsync --tail=30 2>/dev/null || true

    echo "--- Velero BSL status ---"
    kubectl --context "$profile" -n velero get backupstoragelocations -o wide 2>/dev/null || true

    echo "--- Velero logs (last 20) ---"
    kubectl --context "$profile" -n velero logs deploy/velero --tail=20 2>/dev/null || true

    echo "--- VolSync rsync-tls pod logs ---"
    for ns in $(kubectl --context "$profile" get ns -o name 2>/dev/null | grep test-disapp); do
        nsname=${ns#namespace/}
        for pod in $(kubectl --context "$profile" -n "$nsname" get pods -l app.kubernetes.io/created-by=volsync -o name 2>/dev/null); do
            echo "Pod: $nsname/$pod"
            kubectl --context "$profile" -n "$nsname" logs "$pod" --tail=30 2>/dev/null || true
        done
    done

    echo "--- ServiceExport/ServiceImport ---"
    kubectl --context "$profile" get serviceexport,serviceimport -A 2>/dev/null || true

    echo "--- GlobalIngressIP ---"
    kubectl --context "$profile" get globalingressip -A 2>/dev/null || true

    echo "--- Submariner connections ---"
    subctl show connections --context "$profile" 2>/dev/null || true

    echo "--- Submariner diagnose ---"
    subctl diagnose all --context "$profile" 2>/dev/null || true

    echo "--- GlobalIngressIP events ---"
    kubectl --context "$profile" get events --field-selector involvedObject.kind=GlobalIngressIP -A 2>/dev/null || true

    echo "--- Lighthouse CoreDNS logs (last 30) ---"
    kubectl --context "$profile" -n submariner-operator logs -l app=submariner-lighthouse-coredns --tail=30 2>/dev/null || true

    echo "--- Submariner routeagent logs (last 30) ---"
    kubectl --context "$profile" -n submariner-operator logs -l app=submariner-routeagent --tail=30 2>/dev/null || true
}
