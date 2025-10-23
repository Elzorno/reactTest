# Student Hosting Provisioning Scripts

This repository contains automation helpers for preparing a CentOS/Rocky/Alma Linux VPS to host student web sites.

## `scripts/setup_lamp_sftp.sh`

Creates a base LAMP stack (Apache, PHP, MariaDB) and configures SFTP-only access for members of the `sftpusers` group.

### Usage

```bash
sudo bash scripts/setup_lamp_sftp.sh
```

The script will:

* Install Apache, PHP, MariaDB, and supporting packages via `dnf`/`yum`.
* Enable and start Apache (`httpd`), MariaDB, and `firewalld` services.
* Open HTTP, HTTPS, and SSH services in the firewall if `firewalld` is running.
* Create the `/var/www/students` hierarchy that will hold individual student web roots.
* Configure `sshd` so that members of the `sftpusers` group are chrooted to `/var/www/students/<username>` with SFTP-only access.
* Apply SELinux labels so Apache can read/write within the student directories when SELinux is enforcing.

After the script completes, run `mysql_secure_installation` and start adding users that belong to the `sftpusers` group.

## `scripts/create_students_from_csv.sh`

Consumes a CSV export of students (`firstname,lastname,studentID`) and provisions:

* Linux SFTP accounts rooted at `/var/www/students/<studentID>`
* Apache `public_html` folders that resolve as `https://<domain>/~<studentID>`
* Dedicated MariaDB databases and credentials for each student ID
* A CSV credential report for distribution

### Usage

```bash
# Optionally export MYSQL_PWD or point at a password file so the script can talk to MariaDB.
export MYSQL_PWD='<root-password>'

sudo bash scripts/create_students_from_csv.sh \
  --file students.csv \
  --domain www.example.edu \
  --mysql-user root
```

* `--domain` is used to display the public URL for each account. The Apache `UserDir` configuration is written automatically if it is not present.
* The script expects the `sftpusers` group and `/var/www/students` hierarchy created by `setup_lamp_sftp.sh`.
* Provide MySQL credentials either via `MYSQL_PWD`/`~/.my.cnf` or `--mysql-password-file /path/to/secret` to avoid interactive prompts.
* Student IDs are normalized to lowercase alphanumeric characters (and underscores) so they can be used as Linux and MariaDB identifiers.

Every execution produces a timestamped CSV (e.g., `student_credentials_20240101120000.csv`) with the Linux and MariaDB passwords that were generated. Store or transmit this file securely and delete it when it is no longer needed.
