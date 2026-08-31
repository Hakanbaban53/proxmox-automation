#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 4: install Semaphore UI + the Ansible execution environment
# inside sem-01 (run by create-sem-01.sh via pct exec; manual reruns are
# safe - every step is either idempotent or guarded).
#
# Every non-obvious choice here was verified against the real artifacts,
# not copied from a blog:
#   - Semaphore v2.19.11 .deb contains ONLY /usr/bin/semaphore - no
#     systemd unit, no config - so both are created below (unit template
#     from the official "Run as a service" doc).
#   - config.json: "port" MUST be a STRING ("3000"), not a number - the
#     binary refuses to start otherwise with a json unmarshal panic.
#     (Field-verified against the v2.19.11 binary, 28 Aug 2026.)
#   - Database: Semaphore's own default dialect is SQLite (no database
#     server to run); the file lives in /var/lib/semaphore. Postgres is
#     an env-var switch later if HA/remote runners ever need it.
#   - Ansible and the proxmoxer Python library come from Ubuntu's apt -
#     pip is PEP 668-blocked (externally-managed) on 26.04, and apt
#     avoids the venv machinery entirely.
#   - Locale (field-found on sem-01, 28 Aug 2026, second bug of the
#     same install): pct exec inherits the calling shell's LANG
#     (pve-a exports en_US.UTF-8), which this minimal container has
#     not generated. perl only warns about it; ansible-core refuses
#     to run at all ("could not initialize the preferred locale").
#     The script exports C.UTF-8 (built into glibc, no locale-gen
#     needed) and generates en_US.UTF-8 so future pct exec / SSH
#     sessions inherit a locale the container can actually satisfy.
#   - Ownership (field-found on sem-01, 28 Aug 2026, third bug of the
#     same install): the config write, the migrations, and the admin
#     creation all run as root, but the systemd unit runs the binary
#     as the semaphore user. Without an explicit chown the unit dies
#     in a restart loop within milliseconds: it cannot read a
#     640-root:root config.json and cannot open the root-owned
#     SQLite database. The script hands both to the service user.
#   - Cookie keys (field-found on sem-01, 28 Aug 2026, fourth bug of
#     the same install): v2.19 signs session cookies, and the binary
#     requires two secrets in the config: cookie_hash and
#     cookie_encryption (NOT the pre-2.19 names cookie_hash_key /
#     cookie_encryption_key still circulating in blogs; the json tags
#     above come from the binary itself). Without them the server
#     starts fine, the login form renders, the password verifies -
#     and the sign-in dies with HTTP 500 "Failed to create session"
#     because the cookie cannot be encoded. `semaphore setup`
#     generates these; a hand-written minimal config does not.
# ---------------------------------------------------------------------------
set -euo pipefail

# Locale hardening - see the header note. Must precede every ansible
# invocation in this script.
export LANG=C.UTF-8 LC_ALL=C.UTF-8

SEMVER=2.19.11
SEMPORT=3000
SEM_USER=semaphore
SEM_HOME=/home/semaphore
SEM_DATA=/var/lib/semaphore
SEM_CONF=/etc/semaphore/config.json
# Admin password: first argument wins, else it is generated and printed
# at the end. Change it in the UI after first login either way.
# Field-found on sem-01, 28 Aug 2026: the generator must NOT be
# `tr ... | head -c 16`. head closes the pipe after 16 bytes, tr dies
# with "write error: Broken pipe", and under `set -euo pipefail` that
# status rides the command substitution into the assignment and aborts
# the whole script before step 1/8 ever runs. Reading a bounded block
# FIRST (head) and trimming LAST (cut) keeps every exit status at zero.
ADMIN_PASSWORD="${1:-$(head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-16)}"

echo ">>> [1/8] Packages: git, curl, ansible, python libs (proxmoxer, requests)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ansible \
  python3-proxmoxer python3-requests python3-jmespath python3-netaddr \
  openssh-client locales
# community.proxmox 2.0.0's cluster/node info modules require
# proxmoxer >= 2.3, but Ubuntu 26.04's python3-proxmoxer is 2.2.0
# (field-found: the first Health Audit run died at "Read the node
# status" with "Requires proxmoxer 2.3 or newer"). The pip copy
# lands in /usr/local and shadows the apt one - pure-Python library,
# no daemon. PEP 668 blocks plain pip on 26.04, hence the flag.
pip3 install -qq --break-system-packages 'proxmoxer==2.3.0'
# make the commonly inherited en_US.UTF-8 valid for future sessions
# too (idempotent; a no-op once generated):
locale-gen en_US.UTF-8

echo ">>> [2/8] Service user: $SEM_USER (never run Semaphore as root)"
id -u "$SEM_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$SEM_USER"

echo ">>> [3/8] Semaphore binary v$SEMVER (GitHub release .deb)"
if ! /usr/bin/semaphore version 2>/dev/null | grep -q "$SEMVER"; then
  curl -fsSL -o /tmp/semaphore.deb \
    "https://github.com/semaphoreui/semaphore/releases/download/v${SEMVER}/semaphore_${SEMVER}_linux_amd64.deb"
  dpkg -i /tmp/semaphore.deb
  rm -f /tmp/semaphore.deb
else
  echo "    already at v$SEMVER"
fi

echo ">>> [4/8] Config: $SEM_CONF (SQLite dialect, port as STRING)"
# Session cookie secrets for v2.19 (see header note, fourth finding):
# od -N reads EXACTLY N bytes, so no consumer closes the pipe early -
# pipefail-safe, unlike the head -c pattern that caused bug #1.
COOKIE_HASH="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"   # 64 hex
COOKIE_ENC="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"    # 32 hex
install -d -m 755 /etc/semaphore
install -d -o "$SEM_USER" -g "$SEM_USER" -m 750 "$SEM_DATA"
install -d -o "$SEM_USER" -g "$SEM_USER" -m 750 "$SEM_DATA/tmp"
if [ ! -f "$SEM_CONF" ]; then
  cat > "$SEM_CONF" <<EOF
{
  "dialect": "sqlite",
  "sqlite": { "host": "$SEM_DATA/semaphore.db" },
  "port": "$SEMPORT",
  "tmp_path": "$SEM_DATA/tmp",
  "demo": false,
  "cookie_hash": "$COOKIE_HASH",
  "cookie_encryption": "$COOKIE_ENC"
}
EOF
  chmod 640 "$SEM_CONF"
fi
# The unit runs as $SEM_USER and must be able to READ the config:
# 640 root:root kills it at startup with an instant exit 1
# (field-found on sem-01, 28 Aug 2026). Idempotent on re-runs.
chown root:"$SEM_USER" "$SEM_CONF"

echo ">>> [5/8] Database migrations + admin user"
/usr/bin/semaphore --config "$SEM_CONF" migrate
/usr/bin/semaphore --config "$SEM_CONF" users list | grep -q '^admin$' \
  || /usr/bin/semaphore --config "$SEM_CONF" users add \
       --admin --login admin --name "Lab Admin" \
       --email admin@lab.local --password "$ADMIN_PASSWORD"

# migrate and users add ran as root, so everything they created in
# the data dir (semaphore.db first of all) is root-owned and the
# unit's User=semaphore cannot open it (field-found on sem-01, the
# same install). Hand the whole data dir to the service user:
chown -R "$SEM_USER:$SEM_USER" "$SEM_DATA"

echo ">>> [6/8] systemd service (official unit template + service user)"
if [ ! -f /etc/systemd/system/semaphore.service ]; then
  cat > /etc/systemd/system/semaphore.service <<EOF
[Unit]
Description=Semaphore UI (Ansible automation)
Documentation=https://github.com/semaphoreui/semaphore
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SEM_USER
Group=$SEM_USER
WorkingDirectory=$SEM_DATA
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/bin/semaphore server --config=$SEM_CONF
SyslogIdentifier=semaphore
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
fi
systemctl daemon-reload
systemctl enable --now semaphore
systemctl restart semaphore

echo ">>> [7/8] Deploy keypair (git access AND first SSH into new VMs)"
# One key, two jobs, lab scope - see semaphore/README.md for the
# production-grade split (separate keys for repo access and VM access).
if [ ! -f "$SEM_HOME/.ssh/id_ed25519" ]; then
  sudo -u "$SEM_USER" ssh-keygen -t ed25519 -N "" \
    -f "$SEM_HOME/.ssh/id_ed25519" -C "semaphore@sem-01" -q
fi
echo "    public key (authorize this on the git host, ctrl-01):"
sudo -u "$SEM_USER" cat "$SEM_HOME/.ssh/id_ed25519.pub" | sed 's/^/      /'

echo ">>> [8/8] Ansible collections (system path, as root)"
# Install to /usr/share/ansible/collections - the HOME-independent
# system search path - so the collection resolves no matter which
# user/HOME combination runs ansible-playbook (the service user's
# passwd home is /home/semaphore; a user-path install is invisible
# to the task if it lands anywhere else). The first lab install
# went to ~/.ansible instead, and when that galaxy step silently
# failed, Ubuntu's deb-bundled community.proxmox 1.4.0
# (dist-packages) kept serving the old modules: Deploy VM stayed
# green while the first Health Audit died at module resolution
# (field-found, 30 Aug 2026; see README troubleshooting).
# community.proxmox is PINNED to 2.0.0: the playbooks are validated
# against that exact version.
ansible-galaxy collection install \
  -p /usr/share/ansible/collections \
  community.proxmox:2.0.0 community.general ansible.posix

echo
echo "==============================================================="
echo " Semaphore v$SEMVER is up:   http://$(hostname -I | awk '{print $1}'):$SEMPORT"
echo " Login: admin / $ADMIN_PASSWORD   (CHANGE THIS after first login)"
echo "==============================================================="
