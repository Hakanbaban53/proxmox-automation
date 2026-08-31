#!/usr/bin/env bash
# Phase 5b: one-time mail transport setup on sem-01 (run as root there).
#
# The health audit (ansible/playbooks/08_health_audit.yml) prints its
# digest to the task log ALWAYS; this script adds the second delivery
# path - msmtp relaying through Gmail with an app password, so the
# morning/evening digests land in a mailbox nobody has to go looking
# for. msmtp is a send-only client (~1 dependency, no daemon), which
# is exactly the right weight for "mail me the digest twice a day".
#
# Usage (on sem-01, as root):
#   GMAIL_USER='you@gmail.com' \
#   GMAIL_APP_PASSWORD='abcd efgh ijkl mnop' \
#   MAIL_TO='you@gmail.com' \
#   ./sem-01-msmtp.sh
#
# The app password is created at Google Account -> Security ->
# 2-Step Verification -> App passwords. It is NOT the account
# password. /etc/msmtprc ends up mode 600 root-only; the audit runs
# as the semaphore service user, so the script also installs a copy
# the service user can read (~semaphore/.msmtprc, chmod 600) - msmtp
# prefers the user config when it exists.

set -euo pipefail

GMAIL_USER="${GMAIL_USER:?set GMAIL_USER='you@gmail.com'}"
GMAIL_APP_PASSWORD="${GMAIL_APP_PASSWORD:?set GMAIL_APP_PASSWORD='your 16-char app password'}"
MAIL_TO="${MAIL_TO:?set MAIL_TO='recipient@example.com'}"
SEM_USER="${SEM_USER:-semaphore}"

echo "==> installing msmtp"
apt-get update -qq
apt-get install -y -qq msmtp

echo "==> writing /etc/msmtprc (root copy)"
cat > /etc/msmtprc <<EOF
# Managed by scripts/sem-01-msmtp.sh - the audit's mail path (Phase 5b).
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           smtp.gmail.com
port           587
from           ${GMAIL_USER}
user           ${GMAIL_USER}
password       ${GMAIL_APP_PASSWORD}
EOF
chmod 600 /etc/msmtprc

echo "==> writing the service-user copy (~${SEM_USER}/.msmtprc)"
SEM_HOME="$(getent passwd "${SEM_USER}" | cut -d: -f6 || true)"
if [[ -n "${SEM_HOME}" && -d "${SEM_HOME}" ]]; then
  install -o "${SEM_USER}" -g "${SEM_USER}" -m 600 /etc/msmtprc "${SEM_HOME}/.msmtprc"
else
  echo "    user ${SEM_USER} not found - skipping (run the audit as root, or adjust SEM_USER)"
fi

echo "==> making the msmtp log writable by the service user"
# Both msmtp configs log to /var/log/msmtp.log. The test mail below is
# sent as root and would leave the file root-owned; the audit task runs
# msmtp as ${SEM_USER} via ~/.msmtprc, and msmtp treats an unopenable
# logfile as FATAL (no mail sent, non-zero exit) - every audit would go
# red at the mail step while the digest sits safely in the task log.
# Pre-create the log owned by the service user; root keeps appending
# regardless (root ignores file permissions).
touch /var/log/msmtp.log
if getent passwd "${SEM_USER}" >/dev/null 2>&1; then
  chown "${SEM_USER}:${SEM_USER}" /var/log/msmtp.log
fi
chmod 640 /var/log/msmtp.log

echo "==> sending a test mail to ${MAIL_TO}"
printf 'To: %s\nFrom: %s\nSubject: [proxmox-audit] mail path test\n\nmsmtp is configured on this runner. The morning/evening health audit digests will arrive from now on.\n' \
  "${MAIL_TO}" "${GMAIL_USER}" | msmtp -t

echo "==> done. Remember to set in vars/lab-environment.yml:"
echo "      audit_mail_from: \"${GMAIL_USER}\""
echo "      audit_mail_to:   \"${MAIL_TO}\""
