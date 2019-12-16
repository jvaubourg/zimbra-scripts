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
      Email of an account to include in the restore
      Repeat this option as many times as necessary to restore more than only one account
      Cannot be used with -x at the same time
      [Default] All accounts
      [Example] -m foo@example.com -m bar@example.org

    -x email
      Email of an account to exclude of the restore
      Repeat this option as many times as necessary to restore more than only one account
      Cannot be used with -m at the same time
      [Default] No exclusion
      [Example] -x foo@example.com -x bar@example.org

    -f
      Force users to change their password next time they connect after the restore

    -r
      Reset passwords of the restored accounts
      Automatically implies -f option

  ENVIRONMENT

    -i date
      Date corresponding to the archive to restore, for all accounts and the main repository
      [Example] 1970-01-01
      [Default] Last archive is used

    -c path
      Main folder dedicated to this script
      [Default] <zimbra_main_path>_borgbackup (see -p)

      Subfolders will be:
        tmp/: Temporary backups before sending data to Borg
        configs/: See BACKUP CONFIG FILES

    -p path
      Main path of the Zimbra installation
      [Default] ${_zimbra_main_path}

    -u user
      Zimbra UNIX user
      [Default] ${_zimbra_user}

    -g group
      Zimbra UNIX group
      [Default] ${_zimbra_group}

  PARTIAL RESTORE

    -e
      Only restore the accounts (settings + data) but not the server-side settings
      The accounts have to not already exist on the server
      [Default] Everything is restored

  MAIN BORG REPOSITORY
    The main repository contains the backups of the server-side settings (ie. everything except accounts
    themselves), and the Backup Config Files of all the accounts (ie. addresses of the Borg servers with
    the passphrases).

    -a borg_repo
      Full Borg+SSH repository address for the main files
      [Example] mailbackup@mybackups.example.com:main
      [Example] mailbackup@mybackups.example.com:myrepos/main

    -z passphrase
      Passphrase of the Borg repository (see -a)

    -t port
      SSH port to reach all remote Borg servers (see -a and Backup Config Files)
      [Default] ${_borg_repo_ssh_port}

    -k path
      Path to the SSH private key to use to connect to all remote servers (see -a and Backup Config Files)
      This SSH key has to be configured without any passphrase
      [Default] ${_borg_repo_ssh_key}

  BACKUP CONFIG FILES
    See zimbra-borg-backup.sh -h

  OTHERS

    -d LEVEL
      Enable debug mode
      [Default] Disabled

      LEVEL can be:
        1
          Show debug messages
        2
          Show level 1 information plus Zimbra commands
        3
          Show level 2 information plus Bash commands (xtrace)

    -h
      Show this help

  EXAMPLES

    (1) Restore everything from mailbackup@mybackups.example.com (using sshkey.priv and port 2222).
        Server-related data will be restored first (using the :main Borg repo with the -z passphrase),
        then the accounts will be restored one by one, using the Backup Config Files available in the
        :main repo. Last archive of every Borg repo is used

        zimbra-borg-restore.sh\\
          -a mailbackup@mybackups.example.com:main\\
          -z 'JRX2jVkRDpH6+OQ9hw/7sWn4F0OBps42I2TQ6DvRIgI='\\
          -k /root/borg/sshkey.priv\\
          -t 2222

    (2) Restore only the account jdoe@example.com (who is not existing anymore in Zimbra) but
        not the other ones

        zimbra-borg-restore.sh\\
          -a mailbackup@mybackups.example.com:main\\
          -z 'JRX2jVkRDpH6+OQ9hw/7sWn4F0OBps42I2TQ6DvRIgI='\\
          -k /root/borg/sshkey.priv\\
          -t 2222\\
          -m jdoe@example.com

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
  local ask_umount=y

  log_debug "Cleaning after fail"

  if [ "${_debug_mode}" -gt 0 -a \( "${#_used_system_mountpoints[@]}" -gt 0 -o "${#_used_borg_mountpoints[@]}" -gt 0 \) ]; then
    read -p "Umount system and Borg mountpoints in <${_borg_local_folder_tmp}> (default: Y)? " ask_umount
  fi

  if [ -z "${ask_umount}" -o "${ask_umount}" = Y -o "${ask_umount}" = y ]; then
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
  fi

  if [ -d "${_borg_local_folder_tmp}" ]; then
    emptyTmpFolder
    rmdir "${_borg_local_folder_tmp}"
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
      log_err "Unable to have access to the Backup Config Files of the accounts"
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
      log_err "Unable to have access to the Backup Config Files of the accounts"
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

  # Restore Backup Config Files for accounts
  find "${archive_folder}/borg/configs/" -type f -name '*@*' -exec cp -a {} "${_borg_local_folder_configs}" \;

  # Umount the repository
  borg umount "${mount_folder}"
  unset _used_borg_mountpoints["${mount_folder}"]
  rmdir "${mount_folder}"
}

function restoreMain() {
  log_info "Restoring using zimbra-restore.sh"

  FASTZMPROV_TMP="${_fastprompt_zmprov_tmp}" FASTZMMAILBOX_TMP="${_fastprompt_zmmailbox_tmp}" \
    zimbra-restore.sh -d "${_debug_mode}" -i server_settings -b "${_borg_local_folder_tmp}"
}

function selectAccountsToBorgRestore() {
  local accounts_to_restore=
  local mount_folder="${_borg_local_folder_tmp}/accounts"

  mount -o bind "${_borg_local_folder_configs}" "${mount_folder}"
  _used_system_mountpoints["${mount_folder}"]=1

  _backups_path="${_borg_local_folder_tmp}"
  accounts_to_restore=$(selectAccountsToRestore "${_backups_include_accounts}" "${_backups_exclude_accounts}" || true)

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
    borg mount ${_borg_debug_mode} -o allow_other --last 1 "${borg_repo}" "${mount_folder}" > /dev/null || {
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
    borg mount ${_borg_debug_mode} -o allow_other --last 1 "${borg_repo}" "${mount_folder}" > /dev/null || {
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
  local restore_options=()

  if [ "${#_restore_options[@]}" -gt 0 ]; then
    restore_options+=${_restore_options}
  fi

  restore_options+=(-d "${_debug_mode}")
  restore_options+=(-i accounts_settings)
  restore_options+=(-i accounts_data)
  restore_options+=(-b "${_borg_local_folder_tmp}")
  restore_options+=(-m "${email}")

  FASTZMPROV_TMP="${_fastprompt_zmprov_tmp}" FASTZMMAILBOX_TMP="${_fastprompt_zmmailbox_tmp}" \
    zimbra-restore.sh "${restore_options[@]}"

  # Umount repository and bound account folder
  local umounted=false
  until ${umounted}; do
    umount "${account_folder}" && umounted=true || sleep 1
  done
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

_backups_include_accounts=
_backups_exclude_accounts=
_include_all=true
_include_server_settings=false
_include_accounts_full=false
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

while getopts 'm:x:fri:c:p:u:g:ea:z:t:k:d:h' opt; do
  case "${opt}" in
    m) _backups_include_accounts=$(echo -En ${_backups_include_accounts} ${OPTARG}) ;;
    x) _backups_exclude_accounts=$(echo -En ${_backups_exclude_accounts} ${OPTARG}) ;;
    f) _restore_options+=(-f) ;;
    r) _restore_options+=(-r) ;;
    i) _restore_archive_date="${OPTARG}" ;;
    c) _borg_local_folder_main="${OPTARG%/}" ;;
    p) _zimbra_main_path="${OPTARG%/}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    g) _zimbra_group="${OPTARG}" ;;
    e) _include_all=false
       _include_server_settings=false
       _include_accounts_full=true ;;
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

if [ ! -d "${_zimbra_main_path}" -o ! -x "${_zimbra_main_path}" ]; then
  log_err "Zimbra path <${_zimbra_main_path}> doesn't exist, is not a directory or is not executable"
  exit 1
fi


###################
### MAIN SCRIPT ###
###################

initFastPrompts

# Create folders used in this script
install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_main}"
install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_configs}"

if [ -d "${_borg_local_folder_tmp}" ]; then
  emptyTmpFolder
fi

log_info "Mounting and copying files from the main repository"
borgCopyMain

(${_include_all} || ${_include_server_settings}) && {
  log_info "Restoring server-side settings"
  restoreMain
}

(${_include_all} || ${_include_accounts_full}) && {
  _accounts_to_restore=$(selectAccountsToBorgRestore || true)

  if [ -z "${_accounts_to_restore}" ]; then
    log_debug "No account to restore"
  else
    log_debug "Accounts to restore: ${_accounts_to_restore}"

    # Mount & Restore account backups
    for email in ${_accounts_to_restore}; do
      log_info "Restoring account <${email}>"

      if [ ! -f "${_borg_local_folder_configs}/${email}" ]; then
        log_err "${email}: No Backup Config File found for this account"
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
