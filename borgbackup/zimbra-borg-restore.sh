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
      See zimbra-restore.sh -h

    -x email
      See zimbra-restore.sh -h

    -f
      See zimbra-restore.sh -h

    -r
      See zimbra-restore.sh -h

    -n
      Do not restore server-related data (ie. domains, lists, etc), just accounts
      [Default] Server-related data are restored

    -o
      Do not backup any account, just server-related data
      [Default] Accounts are backuped, depending on the -m or -x option (or neither or them)

  ENVIRONMENT

    -i date
      Date corresponding to the archive to restore, for all accounts and the main repository
      [Example] 1970-01-01
      [Default] Last archive is used

    -c path
      Main folder dedicated to this script
      [Default] ${_borg_local_folder_main}

      Subfolders will be:
        tmp/: Temporary backups before sending data to Borg
        configs/: See BACKUP CONFIG FILES

    -p path
      See zimbra-restore.sh -h

    -u user
      See zimbra-restore.sh -h

    -g group
      See zimbra-restore.sh -h

  MAIN BORG REPOSITORY

    [Mandatory] -a borg_repo
      Full Borg+SSH repository address for the main files
      [Example] mailbackup@mybackups.example.com:main
      [Example] mailbackup@mybackups.example.com:myrepos/main

    [Mandatory] -z passphrase
      Passphrase of the Borg repository (see -a)

    -t port
      SSH port to reach all remote Borg servers (see -a and backup config files)
      [Default] ${_borg_repo_ssh_port}

    -k path
      Path to the SSH private key to use to connect to all remote servers (see -a and backup config files)
      This SSH key has to be configured without any passphrase
      [Default] ${_borg_repo_ssh_key}

  BACKUP CONFIG FILES
    See zimbra-borg-backup.sh -h

  OTHERS

    -d LEVEL
      See zimbra-restore.sh -h

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
# Umount all directories currently mounted
function cleanFailedProcess() {
  log_debug "Cleaning after fail"

  if [ "${#_used_system_mountpoints[@]}" -gt 0 ]; then
    for mount_folder in "${!_used_system_mountpoints[@]}"; do
      log_debug "Umounting <${mount_folder}>"
      umount "${mount_folder}"
    done
  fi

  if [ "${#_used_borg_mountpoints[@]}" -gt 0 ]; then
    for mount_folder in "${!_used_borg_mountpoints[@]}"; do
      log_debug "Borg umounting <${mount_folder}>"
      borg umount "${mount_folder}"
    done
  fi
}

# Remove and create again the Borg TMP folder where the backups are done before
# sending data to the server
function emptyTmpFolder() {
  local ask_remove=y

  if [ "${_debug_mode}" -gt 0 ]; then
    read -p "Empty the Borg TMP folder <${_borg_local_folder_tmp}> (default: Y)? " ask_remove
  fi

  if [ -z "${ask_remove}" -o "${ask_remove}" = Y -o "${ask_remove}" = y ]; then
    rm -rf "${_borg_local_folder_tmp}"
    install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_tmp}"
  fi
}

function borgCopyMain() {
  local mount_folder="${_borg_local_folder_tmp}/borg_mount_main"
  local archive_folder=
  local date_archive="${_restore_archive_date}"

  install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${mount_folder}"

  export BORG_PASSPHRASE="${_borg_repo_main_passphrase}"
  export BORG_RSH="ssh -oBatchMode=yes -i ${_borg_repo_ssh_key} -p ${_borg_repo_ssh_port}"

  # The last archive has to be used
  if [ -z "${date_archive}" ]; then

    # Mount the main repository
    borg mount ${_borg_debug_mode} --last 1 "${_borg_repo_main}" "${mount_folder}" > /dev/null || {
      log_err "Unable to mount the main Borg archive (last one)"
      log_err "Unable to have access to the backup config files of the accounts"
      exit 1
    }

    _used_borg_mountpoints["${mount_folder}"]=1

    # Target the only one archive (--last 1) inside the repository
    archive_folder=$(find "${mount_folder}" -mindepth 1 -maxdepth 1 | head -n 1)
    date_archive=$(basename "${archive_folder}")

  # The archive corresponding to the date passed as an option has to be used
  else

    # Mount the main repository
    borg mount ${_borg_debug_mode} "${_borg_repo_main}::${_restore_archive_date}" "${mount_folder}" > /dev/null || {
      log_err "Unable to mount the main Borg archive (${_restore_archive_date})"
      log_err "Unable to have access to the backup config files of the accounts"
      exit 1
    }

    _used_borg_mountpoints["${mount_folder}"]=1
    archive_folder="${mount_folder}"
  fi

  unset BORG_PASSPHRASE BORG_RSH

  log_info "Archive ${date_archive} is used"

  # Copy all files related to the server to the TMP folder, except the folder created by zimbra-borg-backup.sh
  find "${archive_folder}" -maxdepth 1 \! -name borg -exec cp -a {} "${_borg_local_folder_tmp}" \;

  # Create the accounts/ folder which is supposed to be there in a complete backup
  install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_tmp}/accounts"

  # Restore backup config files for accounts
  find "${archive_folder}/borg/configs/" -type f -name '*@*' -exec cp -a {} "${_borg_local_folder_configs}" \;

  # Umount the repository
  borg umount "${mount_folder}"
  unset _used_borg_mountpoints["${mount_folder}"]
  rmdir "${mount_folder}"
}

function restoreMain() {
  log_info "Restoring using zimbra-restore.sh"
  zimbra-restore.sh -d "${_debug_mode}" -e accounts -b "${_borg_local_folder_tmp}"
}

function selectAccountsToBorgRestore() {
  local accounts_to_restore=
  local mount_folder="${_borg_local_folder_tmp}/accounts"

  mount -o bind "${_borg_local_folder_configs}" "${mount_folder}"
  _used_system_mountpoints["${mount_folder}"]=1

  accounts_to_restore=$(selectAccountsToRestore "${_backups_include_accounts}" "${_backups_exclude_accounts}")

  umount "${mount_folder}"
  unset _used_system_mountpoints["${mount_folder}"]

  printf '%s' "${accounts_to_restore}"
}

function borgRestoreAccount() {
  local email="${1}"
  local backup_file="${_borg_local_folder_configs}/${email}"
  local account_folder="${_borg_local_folder_tmp}/accounts/${email}"
  local mount_folder="${_borg_local_folder_tmp}/accounts/borg_mount_${email}"
  local archive_folder=
  local date_archive="${_restore_archive_date}"

  local borg_repo=$(sed -n 1p "${backup_file}")
  local ssh_port=$(sed -n 2p "${backup_file}")
  local passphrase=$(sed -n 3p "${backup_file}")

  install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${account_folder}"
  install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${mount_folder}"

  export BORG_PASSPHRASE="${passphrase}"
  export BORG_RSH="ssh -oBatchMode=yes -i ${_borg_repo_ssh_key} -p ${ssh_port}"

  # The last archive has to be used
  if [ -z "${date_archive}" ]; then

    # Mount the account repository
    borg mount ${_borg_debug_mode} --last 1 "${borg_repo}" "${mount_folder}" > /dev/null || {
      log_err "${email}: Unable to mount the Borg archive (last one)"
      log_err "${email}: Account *NOT* restored"

      unset BORG_PASSPHRASE BORG_RSH
      return
    }

    _used_borg_mountpoints["${mount_folder}"]=1

    # Target the only one archive (--last 1) inside the repository
    archive_folder=$(find "${mount_folder}" -mindepth 1 -maxdepth 1 | head -n 1)
    date_archive=$(basename "${archive_folder}")

  # The archive corresponding to the date passed as an option has to be used
  else

    # Mount the account repository
    borg mount ${_borg_debug_mode} --last 1 "${borg_repo}" "${mount_folder}" > /dev/null || {
      log_err "${email}: Unable to mount the Borg archive (${date_archive})"
      log_err "${email}: Account *NOT* restored"

      unset BORG_PASSPHRASE BORG_RSH
      return
    }

    _used_borg_mountpoints["${mount_folder}"]=1
    archive_folder="${mount_folder}"
  fi

  log_info "${email}: Archive ${date_archive} is used"

  # Mount the archive into the account folder to let zimbra-restore.sh find it
  mount -o bind "${archive_folder}" "${account_folder}"
  _used_system_mountpoints["${account_folder}"]=1

  log_info "${email}: Restoring using zimbra-restore.sh"
  zimbra-restore.sh "${_restore_options[@]}" -d "${_debug_mode}" -e all_except_accounts -b "${_borg_local_folder_tmp}" -m "${email}"

  # Umount repository and bound account folder
  umount "${account_folder}"
  unset _used_system_mountpoints["${account_folder}"]

  borg umount "${mount_folder}"
  unset _used_borg_mountpoints["${mount_folder}"]

  rmdir "${mount_folder}" "${account_folder}"
}


########################
### GLOBAL VARIABLES ###
########################

_log_id=BORG-RESTORE
_borg_debug_mode=--warning # The default one
_borg_local_folder_main=
_borg_local_folder_tmp=
_borg_local_folder_configs=
_borg_repo_main=
_borg_repo_main_passphrase=
_borg_repo_accounts=
_borg_repo_ssh_key=
_borg_repo_ssh_port=22

_backups_path=
_backups_include_accounts=
_backups_exclude_accounts=
_backups_exclude_main=false
_backups_exclude_allaccounts=false
_accounts_to_restore=
_restore_archive_date=
_restore_options=()

declare -A _used_borg_mountpoints
declare -A _used_system_mountpoints

# Traps
trap 'trap_exit $LINENO' EXIT TERM ERR
trap 'exit 1' INT


###############
### OPTIONS ###
###############

while getopts 'm:x:frnoi:c:p:u:g:a:z:t:k:d:h' opt; do
  case "${opt}" in
    m) _backups_include_accounts=$(echo -En ${_backups_include_accounts} ${OPTARG}) ;;
    x) _backups_exclude_accounts=$(echo -En ${_backups_exclude_accounts} ${OPTARG}) ;;
    f) _restore_options+=(-f) ;;
    r) _restore_options+=(-r) ;;
    n) _backups_exclude_main=true ;;
    o) _backups_exclude_allaccounts=true ;;
    i) _restore_archive_date="${OPTARG}" ;;
    c) _borg_local_folder_main="${OPTARG%/}" ;;
    p) _zimbra_main_path="${OPTARG%/}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    g) _zimbra_group="${OPTARG}" ;;
    a) _borg_repo_main="${OPTARG%/}" ;;
    z) _borg_repo_main_passphrase="${OPTARG%/}" ;;
    t) _borg_repo_ssh_port="${OPTARG}" ;;
    k) _borg_repo_ssh_key="${OPTARG}" ;;
    d) _debug_mode="${OPTARG}" ;;
    h) exit_usage 0 ;;
    \?) exit_usage 1 ;;
  esac
done

# Finish to set up variables depending on options
if [ -z "${_borg_local_folder_main}" ]; then
  _borg_local_folder_main="${_zimbra_main_path}_borgbackup"
fi

_borg_local_folder_tmp="${_borg_local_folder_main}/tmp"
_borg_local_folder_configs="${_borg_local_folder_main}/configs"
_backups_path="${_borg_local_folder_main}"

if [ -z "${_borg_repo_ssh_key}" ]; then
  _borg_repo_ssh_key="${_borg_local_folder_main}/private_ssh_key"
fi

# Debug mode
if [ "${_debug_mode}" -ge 3 ]; then
  set -o xtrace
fi

if [ "${_debug_mode}" -ge 2 ]; then
  _borg_debug_mode=--debug
elif [ "${_debug_mode}" -ge 1 ]; then
  _borg_debug_mode=--info
fi

# Check the consistency of the options
if [ -z "${_borg_repo_main}" -o -z "${_borg_repo_main_passphrase}" ]; then
  log_err "Options -a and -z are mandatory"
  exit 1
fi

if [ -n "${_backups_include_accounts}" -a -n "${_backups_exclude_accounts}" ]; then
  log_err "Options -m and -x are not compatible"
  exit 1
fi

if ${_backups_exclude_allaccounts} && [ -n "${_backups_include_accounts}" ]; then
  log_err "Options -n and -m are not compatible"
  exit 1
fi

if [ ! -d "${_zimbra_main_path}" -o ! -x "${_zimbra_main_path}" ]; then
  log_err "Zimbra path <${_zimbra_main_path}> doesn't exist, is not a directory or is not executable"
  exit 1
fi

if ${_backups_exclude_main} && ${_backups_exclude_allaccounts}; then
  log_err "Options -n and -o set: nothing to do"
  exit 0
fi


###################
### MAIN SCRIPT ###
###################

# Create folders used in this script
install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_main}"
install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_configs}"

log_debug "Renew the TMP folder"
emptyTmpFolder

log_info "Mounting and copying files from the main repository"
borgCopyMain

${_backups_exclude_main} || {
  log_info "Restoring server-related data"
  restoreMain
}

${_backups_exclude_allaccounts} || {
  _accounts_to_restore=$(selectAccountsToBorgRestore)

  if [ -z "${_accounts_to_restore}" ]; then
    log_debug "No account to restore"
  else
    log_debug "Accounts to restore: ${_accounts_to_restore}"

    # Mount & Restore account backups
    for email in ${_accounts_to_restore}; do
      log_info "Restoring account <${email}>"

      if [ ! -f "${_borg_local_folder_configs}/${email}" ]; then
        log_err "${email}: No backup config file found for this account"
        log_err "${email}: Will *NOT* be restored"
      else
        resetAccountProcessDuration
        borgRestoreAccount "${email}"
        showAccountProcessDuration
      fi
    done
  fi
}

showFullProcessDuration

exit 0
