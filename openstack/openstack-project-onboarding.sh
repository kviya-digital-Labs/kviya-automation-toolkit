#!/bin/bash

# KVIYA Digital Labs
# OpenStack Project Onboarding Automation
#
# This script automates the onboarding of a new OpenStack project.
#
# Features
# - Create OpenStack project
# - Create user(s) with password
# - Assign member role (no admin privileges)
# - Create private network and subnet
# - Configure router to external network
# - Apply default security group rules
# - Set project quotas (cores, RAM, instances)
#
# Supported Modes
#
# 1. Single Project
#    PROJECT_NAME=acme USERNAME=jdoe PASSWORD=secret ./openstack-project-onboarding.sh
#    ./openstack-project-onboarding.sh acme jdoe secret
#
# 2. Batch Mode
#    ./openstack-project-onboarding.sh --batch projects.csv
#
#    CSV format:
#    project_name,username,password
#
# Optional Environment Variables
#    EXTERNAL_NET_NAME   (default: public)
#    DNS_NAMESERVER      (default: 8.8.8.8)
#    QUOTA_CORES
#    QUOTA_RAM_MB
#    QUOTA_INSTANCES
#    SUBNET_INDEX
#
# Compatible with
# - DevStack
# - Kolla-Ansible
# - Standard OpenStack CLI environments
#
# Developed by
# KVIYA Digital Labs
# https://www.linkedin.com/company/kviya/
#
# License: MIT

set -euo pipefail

# --- Batch mode ---
if [[ "$1" == "--batch" ]] && [[ -n "$2" ]]; then
  if [[ ! -f "$2" ]]; then
    echo "File not found: $2"
    exit 1
  fi
  echo "=== Batch onboarding from $2 ==="
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -z "$line" ]] && continue
    IFS=',' read -r proj user pass <<< "$line"
    if [[ -n "$proj" ]] && [[ -n "$user" ]] && [[ -n "$pass" ]]; then
      PROJECT_NAME="$proj" USERNAME="$user" PASSWORD="$pass" "$0"
    fi
  done < "$2"
  echo "Batch done."
  exit 0
fi

# --- Parse args (single project) ---
if [[ -n "$1" ]]; then PROJECT_NAME="${PROJECT_NAME:-$1}"; fi
if [[ -n "$2" ]]; then USERNAME="${USERNAME:-$2}"; fi
if [[ -n "$3" ]]; then PASSWORD="${PASSWORD:-$3}"; fi

if [[ -z "$PROJECT_NAME" ]] || [[ -z "$USERNAME" ]] || [[ -z "$PASSWORD" ]]; then
  echo "Usage: ./openstack-project-onboarding.sh <project> <username> <password>"
  echo "   or: ./openstack-project-onboarding.sh --batch <file.csv>  # lines: project,username,password"
  exit 1
fi

# Optional: more users as "user2 pass2 user3 pass3" (pairs after first 3 args, or EXTRA_USERS env)
EXTRA_USERS="${EXTRA_USERS:-}"
shift 3 2>/dev/null || true
while [[ -n "$1" ]] && [[ -n "$2" ]]; do
  EXTRA_USERS="$EXTRA_USERS $1 $2"
  shift 2
done

EXTERNAL_NET_NAME="${EXTERNAL_NET_NAME:-public}"
DNS_NAMESERVER="${DNS_NAMESERVER:-8.8.8.8}"
QUOTA_CORES="${QUOTA_CORES:-20}"
QUOTA_RAM_MB="${QUOTA_RAM_MB:-51200}"
QUOTA_INSTANCES="${QUOTA_INSTANCES:-20}"

echo "=== OpenStack project onboarding: $PROJECT_NAME ==="

# --- Resolve member role name (_member_ in older Keystone, member in newer) ---
MEMBER_ROLE=""
for r in _member_ member; do
  if openstack role show "$r" &>/dev/null; then
    MEMBER_ROLE="$r"
    break
  fi
done
if [[ -z "$MEMBER_ROLE" ]]; then
  echo "Error: No member role found (tried _member_, member). Run: openstack role list"
  exit 1
fi
echo "Using role: $MEMBER_ROLE"

# --- 1. Create project ---
if ! openstack project show "$PROJECT_NAME" &>/dev/null; then
  openstack project create "$PROJECT_NAME"
  echo "Created project $PROJECT_NAME"
else
  echo "Project $PROJECT_NAME already exists"
fi

# --- 2. Create primary user with password, assign _member_ only (no admin) ---
if ! openstack user show "$USERNAME" &>/dev/null; then
  openstack user create \
    --project "$PROJECT_NAME" \
    --password "$PASSWORD" \
    --enable \
    "$USERNAME"
  echo "Created user $USERNAME with password"
else
  echo "User $USERNAME already exists"
fi

openstack role add --project "$PROJECT_NAME" --user "$USERNAME" "$MEMBER_ROLE" || true
echo "Role $MEMBER_ROLE assigned to $USERNAME in $PROJECT_NAME (no admin access)"

# --- 3. Extra users (pairs: user pass) ---
while read -r u p; do
  [[ -z "$u" ]] && continue
  if ! openstack user show "$u" &>/dev/null; then
    openstack user create --project "$PROJECT_NAME" --password "$p" --enable "$u"
    echo "Created user $u"
  fi
  openstack role add --project "$PROJECT_NAME" --user "$u" "$MEMBER_ROLE" || true
done < <(echo "$EXTRA_USERS" | xargs -n2 2>/dev/null || true)

# --- 4. Ensure external network exists ---
if ! openstack network show "$EXTERNAL_NET_NAME" &>/dev/null; then
  echo "Error: External network '$EXTERNAL_NET_NAME' not found. Run 03-create-networks.sh first."
  exit 1
fi

# --- 5. Private network + subnet + router for this project ---
priv_net="private-${PROJECT_NAME}"
priv_subnet="private-${PROJECT_NAME}-subnet"
router="router-${PROJECT_NAME}"

if [[ -n "$SUBNET_INDEX" ]]; then
  n="$SUBNET_INDEX"
else
  # Auto-detect next free 10.0.X.0/24 (list subnets, find max X)
  n=1
  for sid in $(openstack subnet list -c ID -f value 2>/dev/null); do
    cidr=$(openstack subnet show -c cidr -f value "$sid" 2>/dev/null)
    if [[ "$cidr" =~ ^10\.0\.([0-9]+)\.0/24 ]]; then
      x="${BASH_REMATCH[1]}"
      [[ -n "$x" ]] && [[ "$x" -ge "$n" ]] && n=$((x + 1))
    fi
  done
fi
cidr="10.0.${n}.0/24"

if ! openstack network show "$priv_net" &>/dev/null; then
  echo "Creating network for $PROJECT_NAME: $priv_net ($cidr)"
  openstack network create --project "$PROJECT_NAME" "$priv_net"
  openstack subnet create \
    --project "$PROJECT_NAME" \
    --network "$priv_net" \
    --subnet-range "$cidr" \
    --dns-nameserver "$DNS_NAMESERVER" \
    "$priv_subnet"
  openstack router create --project "$PROJECT_NAME" "$router"
  openstack router add subnet "$router" "$priv_subnet"
  openstack router set --external-gateway "$EXTERNAL_NET_NAME" "$router"
else
  echo "Network $priv_net already exists"
fi

# --- 6. Security group rules (SSH + ICMP) ---
openstack security group rule create --project "$PROJECT_NAME" --proto tcp --dst-port 22 default 2>/dev/null || true
openstack security group rule create --project "$PROJECT_NAME" --proto icmp default 2>/dev/null || true

# --- 7. Quotas (FinOps) ---
openstack quota set --cores "$QUOTA_CORES" --ram "$QUOTA_RAM_MB" --instances "$QUOTA_INSTANCES" "$PROJECT_NAME"

echo ""
echo "Done. Summary:"
echo "  Project:  $PROJECT_NAME"
echo "  User(s):  $USERNAME (and any extra); role $MEMBER_ROLE only (no admin)"
echo "  Network:  $priv_net ($cidr), router $router → $EXTERNAL_NET_NAME"
echo "  Quotas:   ${QUOTA_CORES} cores, ${QUOTA_RAM_MB} MB RAM, ${QUOTA_INSTANCES} instances"
echo "  Login:    Horizon → project $PROJECT_NAME, user $USERNAME, password <your-password>"
