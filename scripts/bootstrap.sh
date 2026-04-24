#!/usr/bin/env bash
set -euo pipefail

APP_USER="ops"
DISK_DEVICE="/dev/sdb"
PARTITION="${DISK_DEVICE}1"
MOUNT_POINT="/data"
FS_TYPE="xfs"

BASE_DIR="/data/flashyard"
DOCKER_ROOT="/data/docker"

# ===============================
# Environment selection
# ===============================

echo "======================================"
echo " Flashyard Host Bootstrap"
echo "======================================"
echo "1) Staging"
echo "2) Production"
echo

read -rp "Select environment: " ENV_CHOICE

case "$ENV_CHOICE" in
    1) ENV_NAME="staging" ;;
    2) ENV_NAME="production" ;;
    *) echo "Invalid selection."; exit 1 ;;
esac

RUNTIME_DIR="${BASE_DIR}/${ENV_NAME}"

echo
echo "Selected environment: ${ENV_NAME}"
echo "Runtime directory:    ${RUNTIME_DIR}"

# ===============================
# Step selection menu
# ===============================

STEP_NAMES=(
    "Disk Setup        (partition/format ${DISK_DEVICE})"
    "System Packages   (apt install)"
    "Docker Setup      (install + configure)"
    "Flashyard Layout  (create dirs + permissions)"
    "Logrotate         (write /etc/logrotate.d/flashyard)"
    "Validation        (lsblk / df / docker info / tree)"
)

# 1 = enabled, 0 = disabled (all on by default)
STEP_ENABLED=(1 1 1 1 1 1)

print_menu() {
    echo
    echo "======================================"
    echo " Select Steps to Run"
    echo "======================================"
    local i
    for i in "${!STEP_NAMES[@]}"; do
        local num=$(( i + 1 ))
        if [[ "${STEP_ENABLED[$i]}" == "1" ]]; then
            echo "  [x] ${num}. ${STEP_NAMES[$i]}"
        else
            echo "  [ ] ${num}. ${STEP_NAMES[$i]}"
        fi
    done
    echo
    echo "  Toggle: 1-6  |  [a]ll  |  [n]one  |  [r]un"
    echo
}

while true; do
    print_menu
    read -rp "Choice: " MENU_INPUT
    case "$MENU_INPUT" in
        [1-6])
            idx=$(( MENU_INPUT - 1 ))
            if [[ "${STEP_ENABLED[$idx]}" == "1" ]]; then
                STEP_ENABLED[$idx]="0"
            else
                STEP_ENABLED[$idx]="1"
            fi
            ;;
        a) for i in "${!STEP_ENABLED[@]}"; do STEP_ENABLED[$i]="1"; done ;;
        n) for i in "${!STEP_ENABLED[@]}"; do STEP_ENABLED[$i]="0"; done ;;
        r) break ;;
        *) echo "  Invalid choice." ;;
    esac
done

# Verify at least one step is selected
NONE_SELECTED=true
for i in "${!STEP_ENABLED[@]}"; do
    [[ "${STEP_ENABLED[$i]}" == "1" ]] && NONE_SELECTED=false && break
done
if [[ "$NONE_SELECTED" == "true" ]]; then
    echo "No steps selected. Exiting."
    exit 0
fi

echo
echo "======================================"
echo " Running selected steps..."
echo "======================================"

# ===============================
# Step 1: Disk setup
# ===============================

if [[ "${STEP_ENABLED[0]}" == "1" ]]; then
    echo
    echo "==> Step 1: Disk setup"

    read -rp "    WARNING: this will partition/format ${DISK_DEVICE}. Type 'yes' to confirm: " DISK_CONFIRM
    if [[ "$DISK_CONFIRM" != "yes" ]]; then
        echo "    Disk setup aborted."
    else
        if [[ ! -b "$DISK_DEVICE" ]]; then
            echo "ERROR: Disk $DISK_DEVICE not found."
            exit 1
        fi

        if lsblk -no NAME "$DISK_DEVICE" | grep -q "$(basename "$PARTITION")"; then
            echo "    Partition exists, skipping partitioning."
        else
            sudo parted -s "$DISK_DEVICE" mklabel gpt
            sudo parted -s "$DISK_DEVICE" mkpart primary "$FS_TYPE" 0% 100%
            sudo partprobe "$DISK_DEVICE"
            sudo udevadm settle
        fi

        if blkid "$PARTITION" >/dev/null 2>&1; then
            echo "    Filesystem exists, skipping format."
        else
            sudo mkfs."$FS_TYPE" -f "$PARTITION"
        fi

        sudo mkdir -p "$MOUNT_POINT"

        UUID="$(blkid -s UUID -o value "$PARTITION")"

        if ! grep -q "$UUID" /etc/fstab; then
            echo "UUID=${UUID} ${MOUNT_POINT} ${FS_TYPE} defaults,noatime 0 2" | sudo tee -a /etc/fstab >/dev/null
        fi

        sudo mount -a
        sudo chown -R "${APP_USER}:${APP_USER}" "$MOUNT_POINT"
    fi
else
    echo
    echo "==> Step 1: Disk setup skipped"
fi

# ===============================
# Step 2: System packages
# ===============================

if [[ "${STEP_ENABLED[1]}" == "1" ]]; then
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
else
    echo
    echo "==> Step 2: System packages skipped"
fi

# ===============================
# Step 3: Docker setup
# ===============================

if [[ "${STEP_ENABLED[2]}" == "1" ]]; then
    echo
    echo "==> Step 3: Docker setup"

    if ! command -v docker >/dev/null 2>&1; then
        sudo install -m 0755 -d /etc/apt/keyrings

        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

        sudo chmod a+r /etc/apt/keyrings/docker.gpg

        . /etc/os-release

        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    sudo mkdir -p "$DOCKER_ROOT"
    sudo mkdir -p /etc/docker

    sudo tee /etc/docker/daemon.json >/dev/null <<EOF
{
"data-root": "${DOCKER_ROOT}"
}
EOF
    
    sudo systemctl enable docker
    sudo systemctl restart docker
    
    sudo usermod -aG docker "$APP_USER"
    
else
    echo "==> Docker setup skipped"
fi

    sudo systemctl enable docker
    sudo systemctl restart docker

    sudo usermod -aG docker "$APP_USER"
else
    echo
    echo "==> Step 3: Docker setup skipped"
fi

# ===============================
# Step 4: Flashyard layout
# ===============================

if [[ "${STEP_ENABLED[3]}" == "1" ]]; then
    echo
    echo "==> Step 4: Create Flashyard layout"

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
else
    echo
    echo "==> Step 4: Flashyard layout skipped"
fi

# ===============================
# Step 5: Logrotate
# ===============================

if [[ "${STEP_ENABLED[4]}" == "1" ]]; then
    echo
    echo "==> Step 5: Configure logrotate"

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
else
    echo
    echo "==> Step 5: Logrotate skipped"
fi

# ===============================
# Step 6: Validation
# ===============================

if [[ "${STEP_ENABLED[5]}" == "1" ]]; then
    echo
    echo "==> Step 6: Validation"

    lsblk -f

    if [[ "${STEP_ENABLED[0]}" == "1" ]]; then
        df -h "$MOUNT_POINT" || true
    fi

    if [[ "${STEP_ENABLED[2]}" == "1" ]]; then
        sudo docker info | grep "Docker Root Dir" || true
    fi

    if command -v tree >/dev/null 2>&1; then
        tree -L 3 "$BASE_DIR"
    else
        find "$BASE_DIR" -maxdepth 3 -type d | sort
    fi
else
    echo
    echo "==> Step 6: Validation skipped"
fi

echo
echo "======================================"
echo " Bootstrap completed for ${ENV_NAME}"
echo "======================================"
echo "IMPORTANT:"
echo "Re-login required for docker group."
echo "Review /etc/fstab and /etc/docker/daemon.json for correctness."
echo "Check logs in ${BASE_DIR}/logs/ for any issues."
