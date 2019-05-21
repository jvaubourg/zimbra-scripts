#!/bin/bash
# Julien Vaubourg <ju.vg> (2019)
# https://github.com/jvaubourg/zimbra-scripts

set -o errtrace
set -o pipefail
set -o nounset


#############
## HELPERS ##
#############

function show_usage() {
  cat <<USAGE
  MAILBOXES
    -m email
      Email of the account to backup
      Default: All accounts
    -s path
      Path of a folder to skip when backuping data from accounts
      Repeat this option as many times as necessary to exclude more than only one folder
      Default: None
      Example: -e /Inbox/lists -e /Briefcase/films

  ENVIRONMENT
    -b path
      Where to save the backups
      Default: ${_backups_path}
    -p path
      Main path of the Zimbra installation
      Default: ${_zimbra_main_path}
    -u user
      Zimbra UNIX user
      Default: ${_zimbra_user}
    -g group
      Zimbra UNIX group
      Default: ${_zimbra_group}

  EXCLUSIONS
    -e ASSET
      Do a partial backup, by excluding some settings/data
      Repeat this option as many times as necessary to exclude more than only one asset
      Default: None
      Example: -e domains -e data

      ASSET can be:
        admins
          Do not backup the list of admin accounts
        domains
          Do not backup domains
        lists
          Do not backup mailing lists
        data
          Do not backup contents of the mailboxes
        filters
          Do not backup sieve filters
        aliases
          Do not backup email aliases
        signatures
          Do not backup registred signatures

  OTHERS
    -d LEVEL
      Debug mode
      Default: Disabled

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

  exit 1
}

function log() { echo "$(date +'%F %R'): ${1}" }
function log_debug() { [ "${_debug_mode}" -ge 1 ] && log "[DEBUG] ${1}" }
function log_info() { log "[INFO] ${1}" }
function log_warn() { log "[WARN] ${1}" }
function log_err() { log "[ERR] ${1}" }

function trap_exit() {
  local status=$?
  local error=${1}

  trap - EXIT ERR INT

  if [ "${status}" -ne 0 ]; then
    log_err "There was an error on line ${1}"
    log_err "Backup aborted"

    cleanFailedBackup
  else
    log_info "Backup done"
  fi

  exit "${status}"
}

function cleanFailedBackup() {
  if [ ! -z "${_backuping_account}" -a -d "${_backups_path}/accounts/${_backuping_account}" ]; then
    log_debug "Removing failed account backup <${_backuping_account}>"
    rm -ir "${_backups_path}/accounts/${_backuping_account}"
  fi
}

function execZimbraCmd() {
  local cmd="${1}"
  export PATH="${PATH}:${_zimbra_main_path}/bin:${_zimbra_main_path}/libexec/"
  
  if [ "${_debug_mode}" -ge 2 ]; then
    log_debug "CMD: ${cmd}"
  fi

  su "${_zimbra_user}" -c "${cmd}"
}

# Usable after zimbraBackupAccountSettings
function extractFromSettings() {
  local email="${1}"
  local field="${2}"
  local settings_file="${_backups_path}/accounts/${email}/settings"
  local value=$((grep '^${field}:' "${settings_file}" || true) | sed "s/^${field}: //")

  echo -n "${value}"
}


######################
## ZIMBRA CLI & API ##
######################

function zimbraGetDomains() {
  execZimbraCmd 'zmprov --ldap getAllDomains'
}

function zimbraGetAccounts() {
  execZimbraCmd 'zmprov --ldap getAllAccounts' | grep -vE '^(spam\.|ham\.|virus-quarantine\.|galsync[.@])'
}

function zimbraGetAdminAccounts() {
  execZimbraCmd 'zmprov --ldap getAllAdminAccounts'
}

function zimbraGetLists() {
  execZimbraCmd 'zmprov --ldap getAllDistributionLists'
}

function zimbraGetListMembers() {
  local list_email="${1}"
  execZimbraCmd "zmprov --ldap getDistributionListMembership '${list_email}'"
}

function zimbraGetAccountSettings() {
  local email="${1}"
  execZimbraCmd "zmprov --ldap getAccount '${email}'"
}

function zimbraGetAliases() {
  local email="${1}"
  extractFromSettings "${email}" zimbraMailAlias
}

function zimbraGetFilters() {
  local email="${1}"
  execZimbraCmd "zmprov getAccount '${email}' zimbraMailSieveScript" | sed '1d;s/^zimbraMailSieveScript: //'
}

function zimbraGetSignatures() {
  local email="${1}"
  execZimbraCmd "zmprov getSignatures '${email}'"
}

function zimbraGetFoldersList() {
  local email="${1}"
  execZimbraCmd "zmmailbox --zadmin --mailbox '${email}' getAllFolders" | awk '/\// { print $5 }'
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

    log_debug "Get members of the list <${list_email}>"
    zimbraGetListMembers "${list_email}" | grep @ | grep -v '^#' > "${backup_file}"
  done
}

function zimbraBackupAccountData() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/data.tgz"
  local filter_query=

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  if ! [ -z "${_backups_exclude_paths}" ]; then
    local folders=$(zimbraGetFoldersList "${email}")

    # Zimbra fails if a non-existing folder is mentioned in the filter query (even with a "not under")
    for path in ${_backups_exclude_paths}; do
      if echo "${folders}" | grep -q "^${path%/}\$"; then
        filter_query="${filter_query} and not under:${path%/}"
      else
        log_info "Path <${path%/}> doesn't exist for <$email>"
      fi
    done

    if ! [ -z "${filter_query}" ]; then
      filter_query="&query=${filter_query/ and /}"
    fi

    log_debug "Data filter query is <${filter_query}> for <$email>"
  fi

  execZimbraCmd "zmmailbox --zadmin --mailbox '${email}' getRestURL '//?fmt=tgz${filter_query}' > '${backup_file}'"
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
  zimbraGetAliases "${email}" > "${backup_file}"
}

function zimbraBackupAccountFilters() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/filters"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"
  zimbraGetFilters "${email}" > "${backup_file}"
}

function zimbraBackupAccountSignatures() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/signatures"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  # Save signatures individually in files 1, 2, 3, etc
  zimbraGetSignatures | awk "/^# name / { next; file='${backup_path}/signatures/'++i } { print > file }"

  # Every signature file has to be parsed to reorganize the information inside
  for signature_file in $(find "${backup_path}/signatures/" -mindepth 1); do
    local extension='txt'

    # Save the name of the signature from the Zimbra field
    local name=$((grep '^zimbraSignatureName: ' "${tmp_backup_file}" || true) | sed 's/^zimbraSignatureName: //')

    # A signature with no name is possible with older versions of Zimbra
    if [ -z "${name}" ]; then
      log_warn "One signature from <${email}> not saved (no name)"
    else

      # A field zimbraPrefMailSignatureHTML instead of zimbraPrefMailSignature means an HTML signature
      if grep -q zimbraPrefMailSignatureHTML "${tmp_backup_file}"; then
        extension=html
      fi

      local backup_file="${tmp_backup_file}.${extension}"

      # Remove the field name prefixing the signature
      sed 's/zimbraPrefMailSignature\(HTML\)\?: //' -i "${tmp_backup_file}"

      # Remove every line corresponding to a Zimbra field and not the signature content itself
      grep -iv '^zimbra[a-z]\+: ' "${tmp_backup_file}" > "${backup_file}"

      # Remove the last empty line and rename the file to indicate if the signature is html or plain text
      sed '${ /^$/d }' -i "${backup_file}"
    fi

    rm "${tmp_backup_file}"
  done
}


########################
### GLOBAL VARIABLES ###
########################

_debug_mode=0
_zimbra_user='zimbra'
_zimbra_group='zimbra'
_zimbra_main_path='/opt/zimbra'
_backups_path='/tmp/backups'
_backups_exclude_paths=
_backuping_account=
_account_to_backup=
_exclude_admins=false
_exclude_domains=false
_exclude_lists=false
_exclude_data=false
_exclude_filters=false
_exclude_aliases=false
_exclude_signatures=false


###############
### OPTIONS ###
###############

while getopts 'm:s:p:u:g:b:e:d:h' opt; do
  case "${opt}" in
    m) _account_to_backup="${OPTARG}" ;;
    s) _backups_exclude_paths=$(echo ${_backups_exclude_paths} ${OPTARG}) ;;
    p) _zimbra_main_path="${OPTARG}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    g) _zimbra_group="${OPTARG}" ;;
    b) _backups_path="${OPTARG}" ;;
    e) for subopt in ${OPTARG}; do
         case "${subopt}" in
           admins) _exclude_admins=true ;;
           domains) _exclude_domains=true ;;
           lists) _exclude_lists=true ;;
           data) _exclude_data=true ;;
           filters) _exclude_filters=true ;;
           aliases) _exclude_aliases=true ;;
           signatures) _exclude_signatures=true ;;
           *) log_err "Value <${OPTARG}> not supported by option -e"; show_usage ;;
         esac ;;
       done
    d) _debug_mode="${OPTARG}" ;;
    h) show_usage ;;
    \?) exit_usage ;;
  esac
done

_backups_exclude_paths=$(echo ${_backups_exclude_paths})

if [ "${_debug_mode}" -ge 3 ]; then
  set -o xtrace
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

trap 'trap_exit $LINENO' EXIT ERR
trap 'exit 1' INT

${_exclude_admins} || {
  log_info "Backuping admin list"
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

accounts="${_account_to_backup}"

if [ -z "${accounts}" ]; then
  accounts=$(zimbraGetAccounts)
fi

for email in ${accounts}; do
  _backuping_account="${email}"

  if [ -e "${_backups_path}/accounts/${email}" ];
    log_warn "Skip <${email}> account (folder already exists)"
  else

    log_info "Backuping general settings from <${email}>"
    zimbraBackupAccountSettings "${email}"

    ${_exclude_aliases} || {
      log_info "Backuping aliases from <${email}>"
      zimbraBackupAccountAliases "${email}"
    }

    ${_exclude_filters} || {
      log_info "Backuping filters from <${email}>"
      zimbraBackupAccountFilters "${email}"
    }

    ${_exclude_signatures} || {
      log_info "Backuping signatures from <${email}>"
      zimbraBackupAccountSignatures "${email}"
    }

    ${_exclude_data} || {
      log_info "Backuping data from <${email}>"
      zimbraBackupAccountData "${email}"
    }
  fi

  _backuping_account=
done

exit 0
