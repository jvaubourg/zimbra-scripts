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

    -c path
      Main folder dedicated to this script
      [Default] ${_borg_local_folder_main}

      Subfolders will be:
        tmp/: Temporary backups before sending data to Borg
        configs/: See BACKUP CONFIG FILES

    -p path
      See zimbra-backup.sh -h

    -u user
      See zimbra-backup.sh -h

    -g group
      See zimbra-backup.sh -h

  MAIN BORG REPOSITORY

    [Mandatory] -a borg_repo
      Full Borg repository address for the main files (ie. for everything except accounts)
      Passphrases of the repositories created for backuping the accounts will be saved in this repo
      [Example] mailbackup@mybackups.example.com:myrepos/main

    [Mandatory] -z passphrase 
      Passphrase of the Borg repository (see -a)

    -t port
      SSH port to reach the remote Borg server (see -a and -r)
      [Default] ${_borg_repo_ssh_port}

    -k path
      Path to the SSH private key to use to connect to the remote servers (see -a and -r)
      This SSH key has to be configured without any passphrase
      [Default] ${_borg_repo_ssh_key}

  DEFAULT BACKUP OPTIONS
    These options will be used as default when creating a new backup config file (along with -t and -k)

    [Mandatory] -r borg_repo
      Full Borg address of a folder where to create the new repositories for the accounts
      [Example] mailbackup@mybackups.example.com:myrepos

    -s path
      See zimbra-backup.sh -h

    -e ASSET
      See zimbra-backup.sh -h

      ASSET is restricted to:
        aliases
        signatures
        filters
        data

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

# Called by the main trap if an error occured and the script stops
# Currently do nothing (Borg cannot really fail in the middle of an archive creation)
function cleanFailedProcess() {
  log_debug "Cleaning after fail"
}

# Remove and create again the Borg TMP folder where the backups are done before
# sending data to the server
function regenerateTmpFolder() {
  rm -rf "${_borg_local_folder_tmp}"
  install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_tmp}"
}

# Create a config backup file for an account, containing the information about how to
# connect to the Borg server for this account, and so the repository to use
# This function is only called when such a file doesn't already exist and uses the default
# settings passed as options to the script
function createAccountBackupFile() {
  local email="${1}"
  local backup_file="${2}"
  local hash_email=$(printf '%s' "${email}" | sha256sum | cut -c 1-32)
  local generated_passphrase="$(openssl rand -base64 32)"

  # From this point, spaces in option values are no more preserved :(
  local backup_options=$(printf '%s ' "${_backups_options[@]}")

  printf '%s\n' "${_borg_repo_accounts}/${hash_email}" > "${backup_file}"
  printf '%s\n' "${_borg_repo_ssh_port}" >> "${backup_file}"
  printf '%s\n' "${generated_passphrase}" >> "${backup_file}"
  printf '%s\n' "${backup_options}" >> "${backup_file}"
}

# Backup and send to Borg everything which is not related the account themselves
# (eg. domains, lists, etc). A special "main" repository is used for that
function borgBackupMain() {
  log_info "Backuping using zimbra-backup.sh"
  zimbra-backup.sh -d "${_debug_mode}" -e accounts -b "${_borg_local_folder_tmp}"

  printf '%s\n' "${_accounts_to_backup}" > "${_borg_local_folder_tmp}/accounts_list"
  cp -r "${_borg_local_folder_configs}" "${_borg_local_folder_tmp}/accounts_borg"

  export BORG_PASSPHRASE="${_borg_repo_main_passphrase}"
  export BORG_RSH="ssh -oBatchMode=yes -i ${_borg_repo_ssh_key} -p ${_borg_repo_ssh_port}"

  log_debug "Try to init the main Borg repository"
  borg init ${_borg_debug_mode} -e repokey "${_borg_repo_main}" &> /dev/null || true

  log_info "Sending data to Borg (new archive $(date +'%Y-%m-%d') in the main repo)"
  pushd "${_borg_local_folder_tmp}" > /dev/null
  borg create ${_borg_debug_mode} --compression lz4 "${_borg_repo_main}::{now:%Y-%m-%d}" . || {
    log_err "The backup on the Borg server might *NOT* be up do date"
  }
  popd > /dev/null

  unset BORG_PASSPHRASE
  unset BORG_RSH
}

# Backup and send to borg only the information and data related to a specific account
# Every account is remotly backuped using a dedicated Borg repository
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

  log_info "${email}: Backuping using zimbra-backup.sh"
  zimbra-backup.sh ${backup_options} -d "${_debug_mode}" -e all_except_accounts -b "${_borg_local_folder_tmp}" -m "${email}"

  export BORG_PASSPHRASE="${passphrase}"
  export BORG_RSH="ssh -oBatchMode=yes -i ${_borg_repo_ssh_key} -p ${ssh_port}"

  log_debug "${email}: Try to init a Borg repository for this account"
  borg init ${_borg_debug_mode} -e repokey "${ssh_repo}" &> /dev/null || true

  log_info "${email}: Sending data to Borg (new archive $(date +'%Y-%m-%d') in the account repo)"
  pushd "${_borg_local_folder_tmp}/accounts/${email}" > /dev/null
  borg create ${_borg_debug_mode} --stats --compression lz4 "${ssh_repo}::{now:%Y-%m-%d}" . || {
    log_err "${email}: The backup on the Borg server is probably *NOT* up do date"
  }
  popd > /dev/null

  unset BORG_PASSPHRASE
  unset BORG_RSH

  log_debug "Delete and recreate TMP folder"
  regenerateTmpFolder
}


########################
### GLOBAL VARIABLES ###
########################

_log_id=BORG-BACKUP
_borg_debug_mode=--warning # The default one
_borg_local_folder_main="${_zimbra_main_path}_borgbackup"
_borg_local_folder_tmp="${_borg_local_folder_main}/tmp"
_borg_local_folder_configs="${_borg_local_folder_main}/configs"
_borg_repo_main=
_borg_repo_main_passphrase=
_borg_repo_accounts=
_borg_repo_ssh_key="${_borg_local_folder_main}/private_ssh_key"
_borg_repo_ssh_port=22

_backups_include_accounts=
_backups_exclude_accounts=
_accounts_to_backup=

declare -a _backups_options

# Traps
trap 'trap_exit $LINENO' EXIT TERM ERR
trap 'exit 1' INT


###############
### OPTIONS ###
###############

while getopts 'm:x:lc:p:u:g:a:z:t:k:r:s:e:d:h' opt; do
  case "${opt}" in
    m) _backups_include_accounts=$(echo -En ${_backups_include_accounts} ${OPTARG}) ;;
    x) _backups_exclude_accounts=$(echo -En ${_backups_exclude_accounts} ${OPTARG}) ;;
    l) _backups_options+=(-l) ;;
    c) _borg_local_folder_main="${OPTARG%/}" ;;
    p) _zimbra_main_path="${OPTARG%/}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    g) _zimbra_group="${OPTARG}" ;;
    a) _borg_repo_main="${OPTARG%/}" ;;
    z) _borg_repo_main_passphrase="${OPTARG%/}" ;;
    t) _borg_repo_ssh_port="${OPTARG}" ;;
    k) _borg_repo_ssh_key="${OPTARG}" ;;
    r) _borg_repo_accounts="${OPTARG%/}" ;;
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

if [ "${_debug_mode}" -ge 2 ]; then
  _borg_debug_mode=--debug
elif [ "${_debug_mode}" -ge 1 ]; then
  _borg_debug_mode=--info
fi

if [ -z "${_borg_repo_main}" -o -z "${_borg_repo_main_passphrase}" -o -z "${_borg_repo_accounts}" ]; then
  log_err "Options -a, -z and -r are mandatory"
  exit 1
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

# Create folders used in this script
install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_main}"
install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_configs}"

log_debug "Delete and recreate TMP folder"
regenerateTmpFolder

if [ -z "${_backups_include_accounts}" ]; then
  log_info "Preparing for accounts backuping"
fi

_accounts_to_backup=$(selectAccountsToBackup "${_backups_include_accounts}" "${_backups_exclude_accounts}")

log_info "Backuping server-related data"
borgBackupMain

if [ -z "${_accounts_to_backup}" ]; then
  log_debug "No account to backup"
else
  log_debug "Accounts to backup: ${_accounts_to_backup}"

  resetAccountProcessDuration

  # Backup accounts
  for email in ${_accounts_to_backup}; do
    log_info "Backuping account <${email}>"
    borgBackupAccount "${email}"
  done

  showAccountProcessDuration
fi

showFullProcessDuration

exit 0
