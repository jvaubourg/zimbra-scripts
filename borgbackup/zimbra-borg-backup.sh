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

source /usr/share/zimbra-scripts/lib/zimbra-common.inc.sh
source /usr/share/zimbra-scripts/lib/zimbra-api.inc.sh

# Help function
function exit_usage() {
  local status="${1}"

  cat <<USAGE

  ACCOUNTS

    -m email
      Email of an account to include in the backup
      Repeat this option as many times as necessary to backup more than only one account
      Cannot be used with -x at the same time
      [Default] All accounts
      [Example] -m foo@example.com -m bar@example.org

    -x email
      Email of an account to exclude of the backup
      Repeat this option as many times as necessary to backup more than only one account
      Cannot be used with -m at the same time
      [Default] No exclusion
      [Example] -x foo@example.com -x bar@example.org

    -l
      Lock the accounts just before starting to backup them
      Locks are NOT removed after the backup: useful when reinstalling the server
      [Default] Not locked

  ENVIRONMENT

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
      SSH port to reach all remote Borg servers (see -a and -r)
      [Default] ${_borg_repo_ssh_port}

    -k path
      Path to the SSH private key to use to connect to all remote servers (see -a and -r)
      This SSH key has to be configured without any passphrase
      [Default] <main_folder>/private_ssh_key (see -c)

  DEFAULT BACKUP OPTIONS
    These options will be used as default when creating a new Backup Config File (along with -t and -k)

    -r borg_repo
      Full Borg+SSH address where to create new repositories for the account
      [Example] mailbackup@mybackups.example.com:
      [Example] mailbackup@mybackups.example.com:myrepos

    -s path
      Path of a folder to skip when backuping the account data
      (can be a POSIX BRE regex for grep between ^ and $)
      Repeat this option as many times as necessary to exclude different kind of folders
      [Default] No exclusion
      [Example] -s /Briefcase/movies -s '/Inbox/list-.*' -s '.*/nobackup'

    -i
      Do not backup the data of the account (ie. folders, mails, contacts, calendars, briefcase, tasks, etc)
      This option means that "-i accounts_settings" will be passed when backuping the account
      [Default] Everything is backuped

  BACKUP CONFIG FILES
    Every account to backup has to be associated to a config file for its backup
    (see -c for the folder location)
    When there is no config file for an account to backup, the file is created with the default
    options (see DEFAULT BACKUP OPTIONS) and a remote "borg init" is executed

    File format:
      Filename: user@domain.tld
        Line1: Full Borg+SSH repository address
        Line2: SSH port to reach the remote Borg server
        Line3: Passphrase for the repository
        Line4: Custom options to pass to zimbra-backup.sh

    Example of content:
        mailbackup@mybackups.example.com:jdoe
        2222
        fBUgUqfp9n5kxu8V/ghbZaMx6Nyrg5FTh4nA70KlohE=
        -s .*/nobackup

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

    (1) Backup everything to mailbackup@mybackups.example.com (using sshkey.priv and port 2222).
        Server-related data will be backuped in the (already existing) :main Borg repo
        (using the -z passphrase) and the users' repos will be created in :users/
        (when no Backup Config File already exists for them in /opt/zimbra_borgackup/configs/)

        zimbra-borg-backup.sh\\
          -a mailbackup@mybackups.example.com:main\\
          -z 'JRX2jVkRDpH6+OQ9hw/7sWn4F0OBps42I2TQ6DvRIgI='\\
          -k /root/borg/sshkey.priv\\
          -t 2222\\
          -r mailbackup@mybackups.example.com:users/

    (2) Backup only the account jdoe@example.com, not the other ones
        If there is a Backup Config File named jdoe@example.com already existing,
        the Borg server described in it will be used. Otherwise, it will be backuped
        on mybackups.example.com (using sshkey.priv and port 2222) in users/<hash>,
        and a Backup Config File will be created in /opt/zimbra_borgackup/configs/

        zimbra-borg-backup.sh\\
          -a mailbackup@mybackups.example.com:main\\
          -z 'JRX2jVkRDpH6+OQ9hw/7sWn4F0OBps42I2TQ6DvRIgI='\\
          -k /root/borg/sshkey.priv\\
          -t 2222\\
          -r mailbackup@mybackups.example.com:users/\\
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

# Called when the script quits
function trap_exit() {
  local status="${?}"
  local line="${1}"

  trap - EXIT TERM ERR INT

  closeFastPrompts
  trap_common_exit "${status}" "${line}"
}

# Called by the common_exit trap when an error occured
# Currently do nothing (Borg cannot really fail in the middle of an archive creation)
function cleanFailedProcess() {
  log_debug "Cleaning after fail"

  # Nothing to do here for now
}

# Remove and create again the Borg TMP folder where the backups are done before
# sending data to the server
function emptyTmpFolder() {
  local ask_remove=yes

  if [ "${_debug_mode}" -gt 0 ]; then
    read -p "Empty the Borg TMP folder <${_borg_local_folder_tmp}> (default: Y)? " ask_remove
    printf '\n'
  fi

  if [ -z "${ask_remove}" ] || [[ "${ask_remove^^}" =~ ^Y(ES)?$ ]]; then
    rm -rf "${_borg_local_folder_tmp}"
    install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_tmp}"
  fi
}

# Create a config backup file for an account, containing the information about how to
# connect to the Borg server for this account, and so the repository to use
# This function is only called when such a file doesn't already exist and uses the default
# settings passed as options to the script
function createAccountBackupConfigFile() {
  local email="${1}"
  local backup_file="${2}"
  local hash_email=$(printf '%s' "${email}" | sha256sum | cut -c 1-32)
  local generated_passphrase="$(openssl rand -base64 32)"
  local separator=/
  local backup_options=

  # Spaces cannot be used in the options
  # (%q output could not be reused without an eval)
  if [ "${#_backups_options[@]}" -gt 0 ]; then
    backup_options=$(printf '%s ' "${_backups_options[@]}")
  fi

  if [ "${_borg_repo_accounts: -1}" = ':' ]; then
    separator=
  fi

  printf '%s\n' "${_borg_repo_accounts}${separator}${hash_email}" > "${backup_file}"
  printf '%s\n' "${_borg_repo_ssh_port}" >> "${backup_file}"
  printf '%s\n' "${generated_passphrase}" >> "${backup_file}"
  printf '%s\n' "${backup_options}" >> "${backup_file}"
}

# Backup and send to Borg everything which is not related the account themselves
# (eg. domains, lists, etc). A special "main" repository is used for that
function borgBackupMain() {
  local new_archive="$(date +'%Y-%m-%d')"

  export BORG_PASSPHRASE="${_borg_repo_main_passphrase}"
  export BORG_RSH="ssh -oBatchMode=yes -i ${_borg_repo_ssh_key} -p ${_borg_repo_ssh_port}"

  log_debug "Check if the main repository is reachable"

  if borg info ${_borg_debug_mode} "${_borg_repo_main}" > /dev/null; then
    log_debug "Check if the archive of the day already exists in the main repo"

    if borg info ${_borg_debug_mode} "${_borg_repo_main}::${new_archive}" &> /dev/null; then
      log_warn "The archive of the day (${new_archive}) already exists"
      log_warn "The backup on the Borg server might *NOT* be up do date"
    else
      log_info "Backuping using zimbra-backup.sh"

      FASTZMPROV_TMP="${_fastprompt_zmprov_tmp}" FASTZMMAILBOX_TMP="${_fastprompt_zmmailbox_tmp}" \
        zimbra-backup.sh -d "${_debug_mode}" -i server_settings -b "${_borg_local_folder_tmp}"

      # Save at the same time all Backup Config Files (and all other files in the Borg folder)
      install -b -m 0700 -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_borg_local_folder_tmp}/borg/"
      find "${_borg_local_folder_main}" -mindepth 1 -maxdepth 1 ! -samefile "${_borg_local_folder_tmp}"\
        -exec cp -a '{}' "${_borg_local_folder_tmp}/borg/" \;

      log_info "Sending data to Borg (new archive ${new_archive} in the main repo)"
      pushd "${_borg_local_folder_tmp}" > /dev/null
      borg create ${_borg_debug_mode} --compression lz4 "${_borg_repo_main}::{now:%Y-%m-%d}" . || {
        log_err "The backup on the Borg server is *NOT* up do date"
      }
      popd > /dev/null
    fi
  else
    log_err "The Borg server or the main repository is currently unusable"
    log_err "The backup on the Borg server is *NOT* up do date"
  fi

  unset BORG_PASSPHRASE BORG_RSH

  log_debug "Renew the TMP folder"
  emptyTmpFolder
}

# Backup and send to borg only the information and data related to a specific account
# Every account is remotly backuped using a dedicated Borg repository
function borgBackupAccount() {
  local email="${1}"
  local backup_file="${_borg_local_folder_configs}/${email}"
  local new_archive="$(date +'%Y-%m-%d')"

  if [ ! -f "${backup_file}" ]; then
    log_info "${email}: Creating a Backup Config File with default options"
    createAccountBackupConfigFile "${email}" "${backup_file}"
  fi

  local borg_repo=$(sed -n 1p "${backup_file}")
  local ssh_port=$(sed -n 2p "${backup_file}")
  local passphrase=$(sed -n 3p "${backup_file}")
  local backup_options=$(sed -n 4p "${backup_file}")

  export BORG_PASSPHRASE="${passphrase}"
  export BORG_RSH="ssh -oBatchMode=yes -i ${_borg_repo_ssh_key} -p ${ssh_port}"

  log_debug "${email}: Try to init a Borg repository for this account"
  borg init ${_borg_debug_mode} -e repokey "${borg_repo}" &> /dev/null || true

  log_debug "${email}: Check if the account repository is reachable"

  if borg info ${_borg_debug_mode} "${borg_repo}" > /dev/null; then
    log_debug "${email}: Check if the archive of the day already exists"

    if borg info ${_borg_debug_mode} "${borg_repo}::${new_archive}" &> /dev/null; then
      log_warn "${email}: The archive of the day (${new_archive}) already exists"
      log_warn "${email}: The backup on the Borg server might *NOT* be up do date"
    else
      log_info "${email}: Backuping using zimbra-backup.sh"

      FASTZMPROV_TMP="${_fastprompt_zmprov_tmp}" FASTZMMAILBOX_TMP="${_fastprompt_zmmailbox_tmp}" \
        zimbra-backup.sh ${backup_options} -d "${_debug_mode}" -i accounts_settings -i accounts_data -b "${_borg_local_folder_tmp}" -m "${email}"

      mv "${_borg_local_folder_tmp}/backup_info" "${_borg_local_folder_tmp}/accounts/${email}"

      log_info "${email}: Sending data to Borg (new archive ${new_archive} in the account repo)"
      pushd "${_borg_local_folder_tmp}/accounts/${email}" > /dev/null
      borg create ${_borg_debug_mode} --stats --compression lz4 "${borg_repo}::{now:%Y-%m-%d}" . || {
        log_err "${email}: The backup on the Borg server is *NOT* up do date"
      }
      popd > /dev/null
    fi
  else
    log_err "${email}: The Borg server or the repository is currently unusable for this account"
    log_err "${email}: The backup on the Borg server is *NOT* up do date"
  fi

  unset BORG_PASSPHRASE BORG_RSH

  log_debug "Renew the TMP folder"
  emptyTmpFolder
}


########################
### GLOBAL VARIABLES ###
########################

_log_id=Z-BORG-BACKUP
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
_accounts_to_backup=
_backups_options=()

# Traps
trap 'trap_exit $LINENO' EXIT TERM ERR
trap 'exit 1' INT


###############
### OPTIONS ###
###############

# Some default values are located in zimbra-common
while getopts 'm:x:lc:p:u:g:a:z:t:k:r:s:i:d:h' opt; do
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
    i) _backups_options+=(-i accounts_settings) ;;
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
  _borg_repo_ssh_key="${_borg_local_folder_main}/ssh/ssh_key"
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
if [ -z "${_borg_repo_main}" -o -z "${_borg_repo_main_passphrase}" -o -z "${_borg_repo_accounts}" ]; then
  log_err "Options -a, -z and -r are mandatory"
  exit 1
fi

if [ -n "${_backups_include_accounts}" -a -n "${_backups_exclude_accounts}" ]; then
  log_err "Options -m and -x are not compatible"
  exit 1
fi

if [ "${#_backups_options[@]}" -gt 0 ] &&\
  (printf '%s\n' "${_backups_options[@]}" | grep -qw -- -s) && (printf '%s\n' "${_backups_options[@]}" | grep -qw -- -i); then
  log_err "Option -s is not usable when the data of the accounts is not intended to be backuped (see -i)"
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

log_debug "Renew the TMP folder"
emptyTmpFolder

log_info "Backuping server-side settings and Backup Config Files"
borgBackupMain

if [ -z "${_backups_include_accounts}" ]; then
  log_info "Preparing for accounts backuping"
fi

_accounts_to_backup=$(selectAccountsToBackup "${_backups_include_accounts}" "${_backups_exclude_accounts}" || true)

if [ -z "${_accounts_to_backup}" ]; then
  log_debug "No account to backup"
else
  log_debug "Accounts to backup: ${_accounts_to_backup}"

  # Backup accounts
  for email in ${_accounts_to_backup}; do
    resetAccountProcessDuration

    log_info "Backuping account <${email}>"
    borgBackupAccount "${email}"

    showAccountProcessDuration
  done
fi

showFullProcessDuration

exit 0
