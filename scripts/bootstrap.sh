#!/usr/bin/env bash
set -euo pipefail

APP_USER="ops"
DISK_DEVICE="/dev/sdb"
PARTITION="${DISK_DEVICE}1"
MOUNT_POINT="/data"
FS_TYPE="xfs"

BASE_DIR="/data/flashyard"
DOCKER_ROOT="/data/docker"

echo "======================================"
echo " Flashyard Host Bootstrap"
echo "======================================"
echo "1) Staging"
echo "2) Production"
echo

read -rp "Select environment: " ENV_CHOICE

case "$ENV_CHOICE" in
    1)
        ENV_NAME="staging"
    ;;
    2)
        ENV_NAME="production"
    ;;
    *)
        echo "Invalid selection."
        exit 1
    ;;
esac

RUNTIME_DIR="${BASE_DIR}/${ENV_NAME}"

echo
echo "Selected environment: ${ENV_NAME}"
echo "Runtime directory: ${RUNTIME_DIR}"
echo "Disk device: ${DISK_DEVICE}"
echo
echo "WARNING: Disk setup may create/format ${PARTITION} if it has no filesystem."
read -rp "Continue? Type yes: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || exit 1

echo
echo "==> Step 1: Disk setup"

if [[ ! -b "$DISK_DEVICE" ]]; then
    echo "ERROR: Disk $DISK_DEVICE not found."
    echo "Check with: lsblk"
    exit 1
fi

if lsblk -no NAME "$DISK_DEVICE" | grep -q "$(basename "$PARTITION")"; then
    echo "Partition $PARTITION already exists. Skipping partition creation."
else
    echo "Creating GPT partition on $DISK_DEVICE"
    sudo parted -s "$DISK_DEVICE" mklabel gpt
    sudo parted -s "$DISK_DEVICE" mkpart primary "$FS_TYPE" 0% 100%
    sudo partprobe "$DISK_DEVICE"
    sleep 2
fi

if blkid "$PARTITION" >/dev/null 2>&1; then
    echo "Filesystem already exists on $PARTITION. Skipping format."
else
    echo "Formatting $PARTITION as $FS_TYPE"
    sudo mkfs."$FS_TYPE" -f "$PARTITION"
fi

sudo mkdir -p "$MOUNT_POINT"

UUID="$(blkid -s UUID -o value "$PARTITION")"

if grep -q "$UUID" /etc/fstab; then
    echo "/etc/fstab already contains UUID $UUID"
else
    echo "Adding $PARTITION to /etc/fstab"
    echo "UUID=${UUID} ${MOUNT_POINT} ${FS_TYPE} defaults,noatime 0 2" | sudo tee -a /etc/fstab >/dev/null
fi

sudo mount -a
sudo chown -R "${APP_USER}:${APP_USER}" "$MOUNT_POINT"

echo
echo "==> Step 2: Install system packages"

sudo apt update
sudo apt install -y \
ca-certificates \
curl \
gnupg \
rsync \
dos2unix \
logrotate \
parted \
xfsprogs \
tree

echo
echo "==> Step 3: Install Docker if missing"

if command -v docker >/dev/null 2>&1; then
    echo "Docker already installed."
else
    sudo install -m 0755 -d /etc/apt/keyrings
    
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    fi
    
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    . /etc/os-release
    
    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    
    sudo apt update
    sudo apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
fi

echo
echo "==> Step 4: Configure Docker data-root"

sudo mkdir -p "$DOCKER_ROOT"
sudo mkdir -p /etc/docker

if [[ -f /etc/docker/daemon.json ]]; then
    sudo cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
fi

sudo tee /etc/docker/daemon.json >/dev/null <<EOF
{
  "data-root": "${DOCKER_ROOT}"
}
EOF

sudo systemctl enable docker
sudo systemctl restart docker

sudo usermod -aG docker "$APP_USER"

echo
echo "==> Step 5: Create Flashyard directory layout"

sudo mkdir -p \
"$RUNTIME_DIR/frontend" \
"$RUNTIME_DIR/scripts" \
"${BASE_DIR}/postgres/data" \
"${BASE_DIR}/volumes" \
"${BASE_DIR}/logs/nginx" \
"${BASE_DIR}/logs/backend" \
"${BASE_DIR}/logs/postgres"

sudo touch "${BASE_DIR}/logs/deploy-${ENV_NAME}.log"

sudo chown -R "${APP_USER}:${APP_USER}" "$BASE_DIR"
sudo chmod -R 750 "$BASE_DIR"
sudo chmod 640 "${BASE_DIR}/logs/deploy-${ENV_NAME}.log"

echo
echo "==> Step 6: Configure logrotate"

sudo tee /etc/logrotate.d/flashyard >/dev/null <<EOF
${BASE_DIR}/logs/*.log
${BASE_DIR}/logs/nginx/*.log
${BASE_DIR}/logs/backend/*.log
${BASE_DIR}/logs/postgres/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

echo
echo "==> Step 7: Validation"

echo
echo "Disk layout:"
lsblk -f

echo
echo "Mount check:"
df -h "$MOUNT_POINT"

echo
echo "Docker root:"
sudo docker info | grep "Docker Root Dir" || true


echo
echo "Flashyard layout:"
if command -v tree >/dev/null 2>&1; then
    tree -L 3 "$BASE_DIR"
else
    find "$BASE_DIR" -maxdepth 3 -type d | sort
fi

echo
echo "======================================"
echo " Bootstrap completed for ${ENV_NAME}"
echo "======================================"
echo
echo "IMPORTANT:"
echo "1. Log out and log back in so docker group membership applies."
echo "2. Copy docker-compose.yml, .env, nginx.conf, and deploy script into:"
echo "   ${RUNTIME_DIR}"
echo "3. Secrets must stay in GitHub Actions, not on this script."