#!/usr/bin/env bash
#
# Bootstraps a CentOS/Rocky/Alma Linux server with Apache, PHP, MariaDB and
# SFTP-only access for a "sftpusers" group.  The script is idempotent and may be
# run multiple times.  It assumes it is executed with root privileges.
set -euo pipefail

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

command_exists() {
  command -v "$1" &>/dev/null
}

resolve_pkg_mgr() {
  if command_exists dnf; then
    echo dnf
  elif command_exists yum; then
    echo yum
  else
    echo "Neither dnf nor yum package manager was found." >&2
    exit 1
  fi
}

install_packages() {
  local pkg_mgr="$1"
  bold "Installing Apache, PHP, MariaDB, and supporting packages..."
  "$pkg_mgr" -y install epel-release >/dev/null 2>&1 || true
  "$pkg_mgr" -y install \
    httpd \
    mariadb-server \
    php \
    php-cli \
    php-mysqlnd \
    php-xml \
    php-gd \
    php-mbstring \
    php-zip \
    policycoreutils-python-utils \
    firewalld >/dev/null
}

configure_services() {
  bold "Enabling and starting Apache, MariaDB, and firewalld..."
  systemctl enable --now httpd
  systemctl enable --now mariadb
  systemctl enable --now firewalld
}

configure_firewall() {
  if systemctl is-active --quiet firewalld; then
    bold "Configuring the firewall for HTTP, HTTPS, and SFTP..."
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --reload
  else
    echo "firewalld is not active; skipping firewall configuration." >&2
  fi
}

harden_apache() {
  bold "Setting default Apache virtual host directory permissions..."
  mkdir -p /var/www/html
  chown -R apache:apache /var/www/html
  chmod -R 2755 /var/www/html
}

setup_sftp_group() {
  local group="sftpusers"
  local base_dir="/var/www/students"
  local sshd_config="/etc/ssh/sshd_config"

  bold "Creating shared SFTP group and directories..."
  groupadd -f "$group"
  mkdir -p "$base_dir"
  chmod 755 "$base_dir"
  chown root:root "$base_dir"

  mkdir -p /etc/skel/public_html
  chmod 755 /etc/skel /etc/skel/public_html

  bold "Configuring sshd for SFTP chroot..."
  if ! grep -q "^Match Group $group" "$sshd_config"; then
    cp "$sshd_config"{,.bak.$(date +%Y%m%d%H%M%S)}
    cat <<CONFIG >>"$sshd_config"

Match Group $group
    ChrootDirectory $base_dir/%u
    ForceCommand internal-sftp
    PasswordAuthentication yes
    X11Forwarding no
    AllowTcpForwarding no
CONFIG
  fi

  systemctl restart sshd
}

set_selinux_contexts() {
  if command_exists getenforce && [[ $(getenforce) != "Disabled" ]]; then
    bold "Configuring SELinux contexts for student web directories..."
    semanage fcontext -a -t httpd_sys_rw_content_t \
      '/var/www/students(/.*)?' || true
    restorecon -Rv /var/www/students || true
  else
    echo "SELinux not enforced; skipping context adjustments." >&2
  fi
}

main() {
  require_root
  local pkg_mgr
  pkg_mgr=$(resolve_pkg_mgr)

  install_packages "$pkg_mgr"
  configure_services
  configure_firewall
  harden_apache
  setup_sftp_group
  set_selinux_contexts

  bold "LAMP stack and SFTP access have been configured."
  echo "Next steps:"
  echo "  * Run 'mysql_secure_installation' to secure the MariaDB server."
  echo "  * Add student accounts with 'useradd -G sftpusers -d /var/www/students/<user> <user>'."
  echo "  * Create per-user web roots at /var/www/students/<user>/public_html."
}

main "$@"
