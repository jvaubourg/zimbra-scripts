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

function exit_usage() {
  local status="${1}"

  cat <<USAGE

  ACCOUNTS
    Accounts with an already existing backup folder will be skipped with a warning.

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

    -s path
      Path of a folder to skip when backuping data from accounts
      Repeat this option as many times as necessary to exclude more than only one folder
      [Default] No exclusion
      [Example] -s /Inbox/lists -s /Briefcase/films

  ENVIRONMENT

    -b path
      Where to save the backups
      [Default] ${_backups_path}

    -p path
      Main path of the Zimbra installation
      [Default] ${_zimbra_main_path}

    -u user
      Zimbra UNIX user
      [Default] ${_zimbra_user}

    -g group
      Zimbra UNIX group
      [Default] ${_zimbra_group}

  EXCLUSIONS

    -e ASSET
      Do a partial backup, by excluding some settings/data
      Repeat this option as many times as necessary to exclude more than only one asset
      [Default] Everything is backuped
      [Example] -e domains -e data

      ASSET can be:
        admins
          Do not backup the list of admin accounts
        domains
          Do not backup domains
        lists
          Do not backup mailing lists
        aliases
          Do not backup email aliases
        signatures
          Do not backup registred signatures
        filters
          Do not backup sieve filters
        data
          Do not backup contents of the mailboxes (ie. folders/emails/contacts/calendar/briefcase/tasks)
        all_except_accounts
          Only backup the accounts (ie. users' settings and contents of the mailboxes)
        all_except_data
          Only backup the contents of the mailboxes

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

USAGE

  # Show help with -h
  if [ "${status}" -eq 0 ]; then
    trap - EXIT
  fi

  exit "${status}"
}

function log() { echo -E "$(date +'%F %T')# ${1}"; }
function log_debug() { ([ "${_debug_mode}" -ge 1 ] && log "[DEBUG] ${1}" >&2) || true; }
function log_info() { log "[INFO] ${1}"; }
function log_warn() { log "[WARN] ${1}" >&2; }
function log_err() { log "[ERR] ${1}" >&2; }

function trap_exit() {
  local status="${?}"
  local line="${1}"

  trap - EXIT TERM ERR INT

  if [ "${status}" -ne 0 ]; then
    if [ "${line}" -gt 1 ]; then
      log_err "There was an unexpected interruption on line ${line}"
    fi

    log_err "Backup aborted"
    cleanFailedBackup
  else
    log_info "Backup done"
  fi

  exit "${status}"
}

function cleanFailedBackup() {
  log_debug "Cleaning after fail"

  if [ ! -z "${_backuping_account}" -a -d "${_backups_path}/accounts/${_backuping_account}" ]; then
    local ask_remove=y
    
    if [ "${_debug_mode}" -gt 0 ]; then
      read -p "Remove failed account backup <${_backups_path}/accounts/${_backuping_account}> (default: Y)? " ask_remove
    fi

    if [ -z "${ask_remove}" -o "${ask_remove}" = Y -o "${ask_remove}" = y ]; then
      if rm -rf "${_backups_path}/accounts/${_backuping_account}"; then
        log_info "The failed backup of <${email}> has been removed"
      fi
    fi

    _backuping_account=
  fi
}

function resetAccountBackupDuration() {
  _backup_timer="${SECONDS}"
}

function showAccountBackupDuration {
  local duration_secs=$(( SECONDS - _backup_timer ))
  local duration_fancy=$(date -ud "0 ${duration_secs} seconds" +%T)

  log_info "Time used for backuping this account: ${duration_fancy}"
}

function showFullBackupDuration {
  local duration_fancy=$(date -ud "0 ${SECONDS} seconds" +%T)

  log_info "Time used for backuping everything: ${duration_fancy}"
}

function execZimbraCmd() {
  # References (namerefs) are not supported by Bash prior to 4.4 (CentOS currently uses 4.3)
  # For now we expect that the parent function defined a cmd variable
  # local -n command="${1}"

  local path="PATH=/sbin:/bin:/usr/sbin:/usr/bin:${_zimbra_main_path}/bin:${_zimbra_main_path}/libexec"
  
  if [ "${_debug_mode}" -ge 2 ]; then
    log_debug "CMD: ${cmd[*]}"
  fi

  # Using sudo instead of su -c and an array instead of a string prevent code injections
  sudo -u "${_zimbra_user}" env "${path}" "${cmd[@]}"
}

# Usable after zimbraBackupAccountSettings
function extractFromAccountSettingsFile() {
  local email="${1}"
  local field="${2}"
  local settings_file="${_backups_path}/accounts/${email}/settings"
  local value=$((grep "^${field}:" "${settings_file}" || true) | sed "s/^${field}: //")

  echo -En "${value}"
}

function setZimbraPermissions() {
  local folder="${1}"

  chown -R "${_zimbra_user}:${_zimbra_group}" "${folder}"
}

function selectAccountsToBackup() {
  local include_accounts="${1}"
  local exclude_accounts="${2}"
  local accounts_to_backup="${include_accounts}"

  # Backup either accounts provided with -m, either all accounts,
  # either all accounts minus the ones provided with -x
  if [ -z "${accounts_to_backup}" ]; then
    accounts_to_backup=$(zimbraGetAccounts)
    log_debug "Existing accounts: ${accounts_to_backup}"
  
    if ! [ -z "${exclude_accounts}" ]; then
      accounts=
  
      for email in ${accounts_to_backup}; do
        if ! [[ "${exclude_accounts}" =~ (^| )"${email}"($| ) ]]; then
          accounts="${accounts} ${email}"
        fi
      done
  
      accounts_to_backup="${accounts}"
    fi
  fi

  echo -E ${accounts_to_backup}
}


######################
## ZIMBRA CLI & API ##
######################

function zimbraGetAdminAccounts() {
  local cmd=(zmprov --ldap getAllAdminAccounts)

  execZimbraCmd cmd
}

function zimbraGetDomains() {
  local cmd=(zmprov --ldap getAllDomains)

  execZimbraCmd cmd
}

function zimbraGetLists() {
  local cmd=(zmprov --ldap getAllDistributionLists)

  execZimbraCmd cmd
}

function zimbraGetListMembers() {
  local list_email="${1}"
  local cmd=(zmprov --ldap getDistributionListMembership "${list_email}")

  execZimbraCmd cmd
}

function zimbraGetAccounts() {
  local cmd=(zmprov --ldap getAllAccounts)

  echo -E $(execZimbraCmd cmd | (grep -vE '^(spam\.|ham\.|virus-quarantine\.|galsync[.@])' || true))
}

function zimbraGetAccountSettings() {
  local email="${1}"
  local cmd=(zmprov --ldap getAccount "${email}")

  execZimbraCmd cmd
}

function zimbraGetAccountAliases() {
  local email="${1}"

  extractFromAccountSettingsFile "${email}" zimbraMailAlias
}

function zimbraGetAccountSignatures() {
  local email="${1}"
  local cmd=(zmprov getSignatures "${email}")

  execZimbraCmd cmd
}

function zimbraGetAccountFilters() {
  local email="${1}"
  local cmd=(zmprov getAccount "${email}" zimbraMailSieveScript)

  execZimbraCmd cmd | sed '1d;s/^zimbraMailSieveScript: //'
}

function zimbraGetAccountFoldersList() {
  local email="${1}"
  local cmd=(zmmailbox --zadmin --mailbox "${email}" getAllFolders)

  execZimbraCmd cmd | awk '/\// { print $5 }'
}

function zimbraGetAccountDataSize() {
  local email="${1}"
  local cmd=(zmmailbox --zadmin --mailbox "${email}" getMailboxSize)

  execZimbraCmd cmd | tr -d ' '
}

function zimbraGetAccountData() {
  local email="${1}"
  local filter_query="${2}"
  local cmd=(zmmailbox --zadmin --mailbox "${email}" getRestURL "//?fmt=tgz${filter_query}")

  execZimbraCmd cmd
}


#############
## BACKUPS ##
#############

function zimbraBackupAdmins() {
  local backup_path="${_backups_path}/admin"
  local backup_file="${backup_path}/admin_accounts"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"
  zimbraGetAdminAccounts > "${backup_file}"
}

function zimbraBackupDomains() {
  local backup_path="${_backups_path}/admin"
  local backup_file="${backup_path}/domains"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"
  zimbraGetDomains > "${backup_file}"
}

function zimbraBackupLists() {
  local backup_path="${_backups_path}/lists"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  for list_email in $(zimbraGetLists); do
    local backup_file="${backup_path}/${list_email}"

    log_debug "Backup members of ${list_email}"
    zimbraGetListMembers "${list_email}" | (grep @ | grep -v '^#' || true) > "${backup_file}"
  done
}

function zimbraBackupAccountSettings() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/settings"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"
  zimbraGetAccountSettings "${email}" > "${backup_file}"
}

function zimbraBackupAccountAliases() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/aliases"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"
  zimbraGetAccountAliases "${email}" > "${backup_file}"
}

function zimbraBackupAccountSignatures() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/signatures"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  # Save signatures individually in files 1, 2, 3, etc
  zimbraGetAccountSignatures "${email}" | awk "/^# name / { file=\"${backup_path}/\"++i; next } { print > file }"

  # Every signature file has to be parsed to reorganize the information inside
  for tmp_backup_file in $(find "${backup_path}" -mindepth 1); do
    local extension='txt'

    # Save the name of the signature from the Zimbra field
    local name=$((grep '^zimbraSignatureName: ' "${tmp_backup_file}" || true) | sed 's/^zimbraSignatureName: //')

    # A signature with no name is possible with older versions of Zimbra
    if [ -z "${name}" ]; then
      log_warn "${email}: One signature not saved (no name)"
    else

      # A field zimbraPrefMailSignatureHTML instead of zimbraPrefMailSignature means an HTML signature
      if grep -q zimbraPrefMailSignatureHTML "${tmp_backup_file}"; then
        extension=html
      fi

      # Remove the field name prefixing the signature
      sed 's/zimbraPrefMailSignature\(HTML\)\?: //' -i "${tmp_backup_file}"

      # Save the name of the signature in the first line
      local backup_file="${tmp_backup_file}.${extension}"
      echo -E "${name}" > "${backup_file}"

      # Remove every line corresponding to a Zimbra field and not the signature content itself
      (grep -iv '^zimbra[a-z]\+: ' "${tmp_backup_file}" || true) >> "${backup_file}"

      # Remove the last empty line and rename the file to indicate if the signature is html or plain text
      sed '${ /^$/d }' -i "${backup_file}"
    fi

    rm "${tmp_backup_file}"
  done
}

function zimbraBackupAccountFilters() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/filters"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"
  zimbraGetAccountFilters "${email}" > "${backup_file}"
}

function zimbraBackupAccountData() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/data.tgz"
  local filter_query=

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  if ! [ -z "${_backups_exclude_paths}" ]; then
    local folders=$(zimbraGetAccountFoldersList "${email}")

    # Zimbra fails if a non-existing folder is mentioned in the filter query (even with a "not under")
    for path in ${_backups_exclude_paths}; do
      if echo -E "${folders}" | grep -q "^${path}\$"; then
        filter_query="${filter_query} and not under:\"${path}\""
      else
        log_info "${email}: Path <${path}> is missing in data"
      fi
    done

    if ! [ -z "${filter_query}" ]; then
      filter_query="&query=${filter_query/ and /}"
    fi

    log_debug "${email}: Data filter query is <${filter_query}>"
  fi

  zimbraGetAccountData "${email}" "${filter_query}" > "${backup_file}"
}


########################
### GLOBAL VARIABLES ###
########################

_backups_include_accounts=
_backups_exclude_accounts=
_backups_exclude_paths=
_backups_path='/tmp/zimbra_backups'
_zimbra_main_path='/opt/zimbra'
_zimbra_user='zimbra'
_zimbra_group='zimbra'
_exclude_admins=false
_exclude_domains=false
_exclude_lists=false
_exclude_settings=false
_exclude_aliases=false
_exclude_signatures=false
_exclude_filters=false
_exclude_data=false
_debug_mode=0
_accounts_to_backup=
_backuping_account=
_backup_timer=


###############
### OPTIONS ###
###############

trap 'trap_exit $LINENO' EXIT TERM ERR
trap 'exit 1' INT

while getopts 'm:x:s:p:u:g:b:e:d:h' opt; do
  case "${opt}" in
    m) _backups_include_accounts=$(echo -E ${_backups_include_accounts} ${OPTARG}) ;;
    x) _backups_exclude_accounts=$(echo -E ${_backups_exclude_accounts} ${OPTARG}) ;;
    s) _backups_exclude_paths=$(echo -E ${_backups_exclude_paths} ${OPTARG%/}) ;;
    b) _backups_path="${OPTARG%/}" ;;
    p) _zimbra_main_path="${OPTARG%/}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    g) _zimbra_group="${OPTARG}" ;;
    e) for subopt in ${OPTARG}; do
         case "${subopt}" in
           admins) _exclude_admins=true ;;
           domains) _exclude_domains=true ;;
           lists) _exclude_lists=true ;;
           aliases) _exclude_aliases=true ;;
           signatures) _exclude_signatures=true ;;
           filters) _exclude_filters=true ;;
           data) _exclude_data=true ;;
           all_except_accounts)
             _exclude_admins=true
             _exclude_domains=true
             _exclude_lists=true ;;
           all_except_data)
             _exclude_admins=true
             _exclude_domains=true
             _exclude_lists=true
             _exclude_settings=true
             _exclude_aliases=true
             _exclude_signatures=true
             _exclude_filters=true ;;
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

if ! [ -d "${_zimbra_main_path}" -a -x "${_zimbra_main_path}" ]; then
  log_err "Zimbra path <${_zimbra_main_path}> doesn't exist, is not a directory or is not executable"
  exit 1
fi

if ! [ -d "${_backups_path}" -a -x "${_backups_path}" -a -w "${_backups_path}" ]; then
  log_err "Backups path <${_backups_path}> doesn't exist, is not a directory or is not writable"
  exit 1
fi


##############
### SCRIPT ###
##############

${_exclude_admins} || {
  log_info "Backuping admins list"
  zimbraBackupAdmins
}

${_exclude_domains} || {
  log_info "Backuping domains"
  zimbraBackupDomains
}

${_exclude_lists} || {
  log_info "Backuping mailing lists"
  zimbraBackupLists
}

log_info "Preparing accounts backuping"

log_debug "Select accounts to backup"
_accounts_to_backup=$(selectAccountsToBackup "${_backups_include_accounts}" "${_backups_exclude_accounts}")

if [ -z "${_accounts_to_backup}" ]; then
  log_debug "No account to backup"
else
  log_debug "Accounts to backup: ${_accounts_to_backup}"

  # Backup accounts
  for email in ${_accounts_to_backup}; do
    if [ -e "${_backups_path}/accounts/${email}" ]; then
      log_warn "Skip account <${email}> (the folder <${_backups_path}/accounts/${email}> already exists)"
    else
      resetAccountBackupDuration

      _backuping_account="${email}"
      log_info "Backuping account <${email}>"
  
      ${_exclude_settings} || {
        log_info "${email}: Backuping settings file"
        zimbraBackupAccountSettings "${email}"
      }
  
      ${_exclude_aliases} || {
        log_info "${email}: Backuping aliases"
        zimbraBackupAccountAliases "${email}"
      }
  
      ${_exclude_signatures} || {
        log_info "${email}: Backuping signatures"
        zimbraBackupAccountSignatures "${email}"
      }
  
      ${_exclude_filters} || {
        log_info "${email}: Backuping filters"
        zimbraBackupAccountFilters "${email}"
      }
  
      ${_exclude_data} || {
        log_info "${email}: Backuping data ($(zimbraGetAccountDataSize "${email}"))"
        zimbraBackupAccountData "${email}"
      }
  
      showAccountBackupDuration
      _backuping_account=
    fi
  done
fi

setZimbraPermissions "${_backups_path}"
showFullBackupDuration

exit 0
