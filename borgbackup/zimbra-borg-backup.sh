#!/bin/bash
# Julien Vaubourg <ju.vg>
# CC-BY-SA (2019)
# https://github.com/jvaubourg/zimbra-scripts

set -o errtrace
set -o pipefail
set -o nounset


#############
## HELPERS ##
#############

source /usr/share/zimbra-scripts/backups/zimbra-common.inc.sh

# Help function
function exit_usage() {
  local status="${1}"

  cat <<USAGE

  ACCOUNTS

    -m email
      See zimbra-backup.sh -h

    -x email
      See zimbra-backup.sh -h

    -l
      See zimbra-backup.sh -h

  ENVIRONMENT

    -a borg_repo
      Full Borg repository address for the main files (everything except accounts)
      [Default] None (mandatory option)
      [Example] mailbackup@mybackups.example.com:myrepos/main

    -k path
      Path to the SSH private key to use to connect to the remote servers (see -a and -r)
      This SSH key has to be configured without any passphrase
      [Default] ${_borg_repo_ssh_key}

    -c path
      Main folder dedicated to this script
      [Default] ${_borg_local_folder_main}

      Subfolders will be:
        tmp/: Temporary backups before syncing with Borg
        configs/: See BACKUP CONFIG FILES

    -p path
      See zimbra-backup.sh -h

    -u user
      See zimbra-backup.sh -h

    -g group
      See zimbra-backup.sh -h

  BACKUP CONFIG FILES
    Every account to backup has to be associated to a config file for its backup (see -c for the folder location)
    When there is no config file for an account to backup, the file is created with the default
    options (see DEFAULT BACKUP OPTIONS) and a remote "borg init" is executed

    File format:
      Filename: user@domain.tld
        Line1: Full Borg repository address over SSH
        Line2: SSH port to reach the remote Borg server
        Line3: Passphrase for the repository
        Line4: Custom options to pass to zimbra-backup.sh

    Example of content:
        mailbackup@mybackups.example.com:myrepos/jdoe
        2222
        fBUgUqfp9n5kxu8V/ghbZaMx6Nyrg5FTh4nA70KlohE=
        -s .*/nobackup

  DEFAULT BACKUP OPTIONS
    These options will be used as default when creating a new backup config file
    
    -r borg_repo
      Full Borg repository address over SSH
      [Default] None (mandatory option)
      [Example] mailbackup@mybackups.example.com:myrepos/jdoe

    -t port
      SSH port to reach the remote Borg server (located with -r)
      [Default] ${_borg_repo_ssh_port}

    -s path
      See zimbra-backup.sh -h

    -e ASSET
      See zimbra-backup.sh -h

      ASSET is restricted to:
        aliases
        signatures
        filters
        data

  OTHERS

    -d LEVEL
      See zimbra-backup.sh -h

    -h
      Show this help

USAGE

  # Show help with -h
  if [ "${status}" -eq 0 ]; then
    trap - EXIT
  fi

  exit "${status}"
}


####################
## CORE FUNCTIONS ##
####################

function cleanFailedProcess() {
  log_debug "Cleaning after fail"
}

function createAccountBackupFile() {
  local email="${1}"
  local backup_file="${2}"
  local hash_email=$(printf '%s' "${email}" | sha256sum | cut -c 1-32)
  local generated_passphrase="$(openssl rand -base64 32)"
  local backup_options=$(printf '"%s" ' "${_backups_options[@]}")

  printf '%s\n' "${_borg_repo_accounts}/${hash_email}" > "${backup_file}"
  printf '%s\n' "${_borg_repo_ssh_port}" >> "${backup_file}"
  printf '%s\n' "${generated_passphrase}" >> "${backup_file}"
  printf '%s\n' "${backup_options}" >> "${backup_file}"
}

function borgBackupAccount() {
  local email="${1}"
  local backup_file="${_borg_local_folder_configs}/${email}"

  if [ ! -f "${backup_file}" ]; then
    log_info "${email}: Creating a backup config file with default options"
    createAccountBackupFile "${email}" "${backup_file}"
  fi

  local ssh_repo=$(sed -n 1p "${backup_file}")
  local ssh_port=$(sed -n 2p "${backup_file}")
  local passphrase=$(sed -n 3p "${backup_file}")
  local backup_options=$(sed -n 4p "${backup_file}")
  local env_config="BORG_PASSPHRASE=${passphrase} BORG_RSH='ssh -oBatchMode=yes -i ${_borg_repo_ssh_key} -p ${ssh_port}'"

  log_debug "${email}: Call zimbra-backup.sh for backuping"
  zimbra-backup.sh ${backup_options} -d "${_debug_mode}" -e all_except_accounts -b "${_borg_local_folder_tmp}" -m "${email}"

  log_debug "${email}: Try to init the Borg repository"
  ${env_config} borg init -e repokey "${ssh_repo}" &> /dev/null || true

  log_info "${email}: Syncing with Borg server"
  ${env_config} borg create --compression lz4 "${ssh_repo}::{now:%Y-%m-%d}" "${_borg_local_folder_tmp}"
}


########################
### GLOBAL VARIABLES ###
########################

_borg_local_folder_main="${_zimbra_main_path}_borgbackup"
_borg_local_folder_tmp="${_borg_local_folder_main}/tmp"
_borg_local_folder_configs="${_borg_local_folder_main}/configs"
_borg_repo_main='borg@testrestore.choca.pics:repo_chocapics'
_borg_repo_accounts='borg@testrestore.choca.pics:repo_chocapics'
_borg_repo_ssh_key="${_borg_local_folder_main}/private_ssh_key"
_borg_repo_ssh_port=22

_backups_include_accounts=
_backups_exclude_accounts=
_backups_lock_accounts=false
_accounts_to_backup=

declare -a _backups_options

# Traps
trap 'trap_exit $LINENO' EXIT TERM ERR
trap 'exit 1' INT


###############
### OPTIONS ###
###############

while getopts 'm:x:la:k:c:p:u:g:r:t:s:e:d:h' opt; do
  case "${opt}" in
    m) _backups_include_accounts=$(echo -En ${_backups_include_accounts} ${OPTARG}) ;;
    x) _backups_exclude_accounts=$(echo -En ${_backups_exclude_accounts} ${OPTARG}) ;;
    l) _backups_lock_accounts=true ;;
    a) _borg_repo_main="${OPTARG%/}" ;;
    k) _borg_repo_ssh_key="${OPTARG}" ;;
    c) _borg_local_folder_main="${OPTARG%/}" ;;
    p) _zimbra_main_path="${OPTARG%/}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    g) _zimbra_group="${OPTARG}" ;;
    r) _borg_repo_accounts="${OPTARG%/}" ;;
    t) _borg_repo_ssh_port="${OPTARG%/}" ;;
    s) _backups_options+=(-s "${OPTARG}") ;;
    e) for subopt in ${OPTARG}; do
         case "${subopt}" in
           aliases|signatures|filters|data) _backups_options+=(-e "${OPTARG}") ;;
           *) log_err "Value <${OPTARG}> not supported by option -e"; exit_usage 1 ;;
         esac
       done ;;
    d) _debug_mode="${OPTARG}" ;;
    h) exit_usage 0 ;;
    \?) exit_usage 1 ;;
  esac
done

if [ "${_debug_mode}" -ge 3 ]; then
  set -o xtrace
fi

if [ ! -z "${_backups_include_accounts}" -a ! -z "${_backups_exclude_accounts}" ]; then
  log_err "Options -m and -x are not compatible"
  exit 1
fi

if [ ! -d "${_zimbra_main_path}" -o ! -x "${_zimbra_main_path}" ]; then
  log_err "Zimbra path <${_zimbra_main_path}> doesn't exist, is not a directory or is not executable"
  exit 1
fi


###################
### MAIN SCRIPT ###
###################

install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_main}"
install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_tmp}"
install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_configs}"

if [ -z "${_backups_include_accounts}" ]; then
  log_info "Preparing accounts borgbackuping"
fi

_accounts_to_backup=$(selectAccountsToBackup "${_backups_include_accounts}" "${_backups_exclude_accounts}")

if [ -z "${_accounts_to_backup}" ]; then
  log_debug "No account to borgbackup"
else
  log_debug "Accounts to borgbackup: ${_accounts_to_backup}"

  # Backup accounts
  for email in ${_accounts_to_backup}; do
    borgBackupAccount "${email}"
  done
fi
