#!/usr/bin/env bash
#
# Batch provisions student accounts, web directories, and MariaDB access from a CSV file.
# CSV must contain rows of firstname,lastname,studentID (with optional header row).
set -euo pipefail

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

usage() {
  cat <<USAGE
Usage: $0 -f students.csv [options]

Options:
  -f, --file PATH                 CSV file with firstname,lastname,studentID columns (required)
  -d, --domain DOMAIN             Domain used for Apache userdir access (for informational output)
      --mysql-user USER           MariaDB administrative user (default: root)
      --mysql-host HOST           MariaDB host (default: local socket)
      --mysql-password-file PATH  File containing MariaDB password (optional)
  -h, --help                      Show this help message

Environment variables:
  MYSQL_PWD can be exported instead of using --mysql-password-file to avoid password prompts.
USAGE
}

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

command_exists() {
  command -v "$1" &>/dev/null
}

read_password_file() {
  local path="$1"
  if [[ ! -r "$path" ]]; then
    echo "Cannot read MySQL password file: $path" >&2
    exit 1
  fi
  MYSQL_PWD=$(<"$path")
  export MYSQL_PWD
}

parse_args() {
  csv_file=""
  domain=""
  mysql_user="root"
  mysql_host=""
  password_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)
        csv_file="$2"
        shift 2
        ;;
      -d|--domain)
        domain="$2"
        shift 2
        ;;
      --mysql-user)
        mysql_user="$2"
        shift 2
        ;;
      --mysql-host)
        mysql_host="$2"
        shift 2
        ;;
      --mysql-password-file)
        password_file="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$csv_file" ]]; then
    echo "CSV file is required." >&2
    usage
    exit 1
  fi

  if [[ ! -f "$csv_file" ]]; then
    echo "CSV file does not exist: $csv_file" >&2
    exit 1
  fi

  if [[ -n "$password_file" ]]; then
    read_password_file "$password_file"
  fi
}

build_mysql_command() {
  mysql_cmd=(mysql --batch --skip-column-names -u "$mysql_user")
  if [[ -n "$mysql_host" ]]; then
    mysql_cmd+=(-h "$mysql_host")
  fi
}

ensure_prerequisites() {
  local missing=()
  for bin in mysql openssl; do
    if ! command_exists "$bin"; then
      missing+=("$bin")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing required commands: ${missing[*]}" >&2
    exit 1
  fi

  if ! getent group sftpusers >/dev/null; then
    echo "The sftpusers group does not exist. Run setup_lamp_sftp.sh first." >&2
    exit 1
  fi

  mkdir -p /var/www/students
  chown root:root /var/www/students
  chmod 755 /var/www/students
}

ensure_userdir_configuration() {
  local module_conf="/etc/httpd/conf.modules.d/00-userdir.conf"
  local conf="/etc/httpd/conf.d/student_userdir.conf"
  local reload_needed=false

  if [[ -f "$module_conf" ]] && grep -q "^#LoadModule userdir_module" "$module_conf"; then
    sed -i 's/^#LoadModule userdir_module/LoadModule userdir_module/' "$module_conf"
    reload_needed=true
  fi

  if [[ ! -f "$conf" ]]; then
    cat <<CONF >"$conf"
# Managed by create_students_from_csv.sh
UserDir disabled root
UserDir enabled
UserDir /var/www/students/*/public_html

<Directory "/var/www/students/*/public_html">
    AllowOverride All
    Options MultiViews Indexes SymLinksIfOwnerMatch IncludesNoExec
    Require all granted
</Directory>
CONF
    reload_needed=true
  fi

  if [[ "$reload_needed" == true ]]; then
    systemctl reload httpd || systemctl restart httpd
  fi
}

sanitize_id() {
  local raw="$1"
  local lowered
  lowered=$(echo "$raw" | tr '[:upper:]' '[:lower:]')
  # Allow alphanumeric characters and underscores only
  lowered=$(echo "$lowered" | tr -cd '[:alnum:]_')
  echo "$lowered"
}

random_password() {
  openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16
}

create_linux_account() {
  local username="$1"
  local full_name="$2"
  local home_base="/var/www/students/$username"
  local linux_password

  if id "$username" &>/dev/null; then
    usermod -a -G sftpusers "$username"
  else
    useradd --badname -M -d "$home_base" -s /sbin/nologin -G sftpusers -c "$full_name" "$username"
  fi

  mkdir -p "$home_base/public_html"
  chown root:root "$home_base"
  chmod 755 "$home_base"

  if [[ -d /etc/skel/public_html && ! -e "$home_base/public_html/index.html" ]]; then
    cp -a /etc/skel/public_html/. "$home_base/public_html"/ 2>/dev/null || true
  fi

  chown "$username":sftpusers "$home_base/public_html"
  chmod 755 "$home_base/public_html"

  linux_password=$(random_password)
  echo "$username:$linux_password" | chpasswd
  echo "$linux_password"
}

create_mysql_resources() {
  local username="$1"
  local password="$2"
  local db_name="$username"
  local host="localhost"

  "${mysql_cmd[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`$db_name\`;
CREATE USER IF NOT EXISTS '$username'@'$host' IDENTIFIED BY '$password';
ALTER USER '$username'@'$host' IDENTIFIED BY '$password';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$username'@'$host';
FLUSH PRIVILEGES;
SQL
}

verify_mysql_connection() {
  if ! "${mysql_cmd[@]}" -e "SELECT 1" >/dev/null 2>&1; then
    echo "Unable to connect to MariaDB with the provided credentials." >&2
    exit 1
  fi
}

process_csv() {
  local output_file="student_credentials_$(date +%Y%m%d%H%M%S).csv"
  echo "student_id,linux_username,linux_password,mysql_username,mysql_password" >"$output_file"

  while IFS=, read -r first_name last_name student_id; do
    # Trim whitespace
    first_name=$(echo "${first_name//\r/}" | xargs)
    last_name=$(echo "${last_name//\r/}" | xargs)
    student_id=$(echo "${student_id//\r/}" | xargs)

    if [[ -z "$first_name$last_name$student_id" ]]; then
      continue
    fi

    if [[ "$first_name" =~ ^[Ff]irst ?[Nn]ame$ ]] || [[ "$student_id" =~ ^[Ss]tudent ?[Ii][Dd]$ ]]; then
      continue
    fi

    local sanitized
    sanitized=$(sanitize_id "$student_id")
    if [[ -z "$sanitized" ]]; then
      echo "Skipping entry with invalid student ID: $student_id" >&2
      continue
    fi

    local normalized_original
    normalized_original=$(echo "$student_id" | tr '[:upper:]' '[:lower:]')
    if [[ "$sanitized" != "$normalized_original" ]]; then
      echo "Normalizing student ID '$student_id' to '$sanitized' for account creation." >&2
    fi

    local full_name
    full_name=$(echo "${first_name} ${last_name}" | xargs)

    bold "Provisioning ${sanitized}..."
    local linux_pass
    local mysql_pass
    linux_pass=$(create_linux_account "$sanitized" "$full_name")
    mysql_pass=$(random_password)
    create_mysql_resources "$sanitized" "$mysql_pass"

    echo "$sanitized,$sanitized,$linux_pass,$sanitized,$mysql_pass" >>"$output_file"

    local protocol="http"
    local web_path
    if [[ -n "$domain" ]]; then
      protocol="https"
    fi
    web_path="${protocol}://${domain:-your-domain}/~$sanitized"
    echo "  Web directory: /var/www/students/$sanitized/public_html"
    echo "  Browser URL:   $web_path"
  done <"$csv_file"

  bold "Provisioning complete. Credentials saved to $output_file"
}

main() {
  require_root
  parse_args "$@"
  ensure_prerequisites
  build_mysql_command
  verify_mysql_connection
  ensure_userdir_configuration
  process_csv
}

main "$@"
