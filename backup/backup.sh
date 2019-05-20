#!/bin/bash
# Julien Vaubourg <ju.vg> (2019)

set -o errtrace
set -o pipefail
set -o nounset


#############
## HELPERS ##
#############

function show_usage() {
  cat <<USAGE
  MAILBOXES
    -m | --mailbox email
      Email of the account to backup
      Default: All accounts
    -e|--data-exclusions paths
      Paths of folders to exclude from the accounts' data
      Default: ${_backups_nobackup_paths}

  ENVIRONMENT
    -b|--backups-path path
      Where to save the backups
      Default: ${_backups_path}
    -p|--zimbra-path path
      Main path of the Zimbra installation
      Default: ${_zimbra_main_path}
    -u|--zimbra-user user
      Zimbra user
      Default: ${_zimbra_user}
    -g|--zimbra-group group
      Zimbra group
      Default: ${_zimbra_group}

  RESTRICTIONS
    --no-admins
      Do not backup the list of admin accounts
    --no-domains
      Do not backup domains
    --no-lists
      Do not backup mailing lists
    --no-data
      Do not backup contents of the mailboxes
    --no-filters
      Do not backup sieve filters
    --no-settings
      Do not backup personal settings
    --no-signatures
      Do not backup registred signatures

  OTHERS
    -h|--help
      Show this help
USAGE

  exit 1
}

function log() { echo "$(date +'%F %R'): ${1}" }
function log_debug() { log "[DEBUG] ${1}" }
function log_info() { log "[INFO] ${1}" }
function log_warn() { log "[WARN] ${1}" }
function log_err() { log "[ERR] ${1}" }

function trap_exit_error() {
  log_err "There was an error on line ${1}"
  log_err "Backup aborted"

  trap_cleaning
  exit 1
}

function trap_cleaning() {
  trap - ERR INT

  if [ ! -z "${_backuping_account}" -a -e "${_backuping_account}" ]
    log_debug "Removing failed account backup <${_backuping_account}>"
    rm -ir "${_backups_path}/accounts/${_backuping_account}"
  fi
}

function execZimbraCmd() {
  local cmd="${1:-}"
  export PATH="${PATH}:${_zimbra_main_path}/bin:${_zimbra_main_path}/libexec/"
  su "${_zimbra_user}" -c "${cmd}"
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
  local list_email="${1:-}"
  execZimbraCmd "zmprov --ldap getDistributionListMembership '${list_email}'"
}

function zimbraGetAccountSettings() {
  local email="${1:-}"
  execZimbraCmd "zmprov --ldap getAccount '${email}'"
}

function zimbraGetFilters() {
  local email="${1:-}"
  execZimbraCmd "zmprov getAccount '${email}' zimbraMailSieveScript" | sed '1d;s/^zimbraMailSieveScript: //'
}

function zimbraGetSignatures() {
  local email="${1:-}"
  execZimbraCmd "zmprov getSignatures '${email}'"
}


#############
## BACKUPS ##
#############

function zimbraBackupAdmins() {
  local backup_path="${_backups_path}/admin"
  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  zimbraGetAdminAccounts > "${backup_path}/admin_accounts"
}

function zimbraBackupDomains() {
  local backup_path="${_backups_path}/admin"
  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  zimbraGetDomains > "${backup_path}/domains"
}

function zimbraBackupLists() {
  local backup_path="${_backups_path}/lists"
  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  for email in $(zimbraGetLists); do
    log_info "Getting members of the list <${email}>"
    zimbraGetListMembers "${email}" | grep @ | grep -v '^#' > "${backup_path}/${email}"
  done
}

function zimbraBackupAccountData() {
  local email="${1:-}"
  local filter_query=${_backups_nobackup_paths// / and not under:}
  local backup_path="${_backups_path}/accounts/${email}"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  if ! [ -z "${filter_query}" ]; then
    filter_query="&query=not under:${filter_query}"
  fi

  log_debug "Filter query: ${filter_query}"
  execZimbraCmd "zmmailbox --zadmin --mailbox '${email}' getRestURL '//?fmt=tgz${filter_query}' > '${backup_path}/data.tgz'"
}

function zimbraBackupAccountSettings() {
  local email="${1:-}"

  local backup_path="${_backups_path}/accounts/${email}"
  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  zimbraGetAccountSettings "${email}" > "${backup_path}/settings"
}

function zimbraBackupAccountFilters() {
  local email="${1:-}"

  local backup_path="${_backups_path}/accounts/${email}"
  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  zimbraGetFilters "${email}" > "${backup_path}/filters"
}

function zimbraBackupAccountSignatures() {
  local email="${1:-}"

  local backup_path="${_backups_path}/accounts/${email}/signatures"
  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  # Save signatures individually in files 1, 2, 3, etc
  zimbraGetSignatures | awk "/^# name / { next; file='${backup_path}/signatures/'++i } { print > file }"

  # Every signature file has to be parsed to reorganize the information inside
  for signature_file in $(find "${backup_path}/signatures/" -mindepth 1); do
    local extension='txt'

    # Save the name of the signature from the Zimbra field
    local name=$((grep '^zimbraSignatureName: ' "${signature_file}" || true) | sed 's/^zimbraSignatureName: //')

    # A signature with no name is possible with older versions of Zimbra
    if [ -z "${name}" ]; then
      log_warn "One signature from <${email}> not saved (no name)"
    else

      # A field zimbraPrefMailSignatureHTML instead of zimbraPrefMailSignature means an HTML signature
      if grep -q zimbraPrefMailSignatureHTML "${signature_file}"; then
        extension=html
      fi

      # Remove the field name prefixing the signature
      sed 's/zimbraPrefMailSignature\(HTML\)\?: //' -i "${signature_file}"

      # Remove every line corresponding to a Zimbra field and not the signature content itself
      grep -iv '^zimbra[a-z]\+: ' "${signature_file}" > "${signature_file}.${extension}"

      # Remove the last empty line and rename the file to indicate if the signature is html or plain text
      sed '${ /^$/d }' -i "${signature_file}.${extension}"
    fi

    rm "${signature_file}"
  done
}


########################
### GLOBAL VARIABLES ###
########################

_zimbra_user='zimbra'
_zimbra_group='zimbra'
_zimbra_main_path='/opt/zimbra'
_backups_path='/tmp/backups'
_backups_nobackup_paths='/Inbox/nobackup /Briefcase/nobackup'
_backuping_account=
_arg_mailbox=
_arg_noadmins=false
_arg_nodomains=false
_arg_nolists=false
_arg_nodata=false
_arg_nofilters=false
_arg_nosettings=false
_arg_nosignatures=false


##############
### SCRIPT ###
##############

trap 'trap_exit_error $LINENO' ERR
trap trap_cleaning INT
options=$(getopt -o m:,e:,p:,u:,g:,b:,h: -l mailbox:,no-admins,no-domains,no-lists,no-data,no-filters,no-settings,no-signatures,data-exclusions,zimbra-path,zimbra-user,zimbra-group,backups-path,help -- "${@}") || exit 1
set -- ${options}

while [ "${#}" -gt 0 ]; do
  case ${1} in
    -m|--mailbox) _arg_mailbox="${2}"; shift ;;
    --no-admins) _arg_noadmins=true ;;
    --no-domains) _arg_nodomains=true ;;
    --no-lists) _arg_nolists=true ;;
    --no-data) _arg_nodata=true ;;
    --no-filters) _arg_nofilters=true ;;
    --no-settings) _arg_nosettings=true ;;
    --no-signatures) _arg_nosignatures=true ;;
    -e|--data-exclusions) _backups_nobackup_paths="${2}"; shift ;;
    -p|--zimbra-path) _zimbra_main_path="${2}"; shift ;;
    -u|--zimbra-user) _zimbra_user="${2}"; shift ;;
    -g|--zimbra-group) _zimbra_group="${2}"; shift ;;
    -b|--backups-path) _backups_path="${2}"; shift ;;
    -h|--help) show_usage ;;
    (-*) log_err "Unrecognized option <${1}>"; show_usage ;;
    (*) break ;;
  esac; shift
done

if ! [ -r "${_zimbra_main_path}" ]; then
  log_err "Zimbra path <${_zimbra_main_path}> doesn't exist or is not readable"
  exit 1
fi

if ! [ -w "${_backups_path}" ]; then
  log_err "Backups path <${_backups_path}> doesn't exist or is not writable"
  exit 1
fi

${_arg_noadmins} || {
  log_info "Backuping admin list"
  zimbraBackupAdmins
}

${_arg_nodomains} || {
  log_info "Backuping domains"
  zimbraBackupDomains
}

${_arg_nolists} || {
  log_info "Backuping mailing lists"
  zimbraBackupLists
}

accounts="${_arg_mailbox}"

if [ -z "${accounts}" ]; then
  accounts=$(zimbraGetAccounts)
fi

for email in ${accounts}; do
  _backuping_account="${email}"

  if [ -e "${_backups_path}/accounts/${email}" ];
    log_warn "Skipping <${email}> account (folder already exists)"
  else

    ${_arg_nosettings} || {
      log_info "Backuping settings from <${email}>"
      zimbraBackupAccountSettings "${email}"
    }

    ${_arg_nofilters} || {
      log_info "Backuping filters from <${email}>"
      zimbraBackupAccountFilters "${email}"
    }

    ${_arg_nosignatures} || {
      log_info "Backuping signatures from <${email}>"
      zimbraBackupAccountSignatures "${email}"
    }

    ${_arg_nodata} || {
      log_info "Backuping data from <${email}>"
      zimbraBackupAccountData "${email}"
    }
  fi

  _backuping_account=
done

log_info "Backup done!"

exit 0
