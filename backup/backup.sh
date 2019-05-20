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
    -s paths
      Paths of folders to skip when backuping data from accounts
      Default: ${_backups_nobackup_paths}

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
    -e TYPE
      Do a partial backup, by excluding some settings/data.

      TYPE can be:
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
        settings
          Do not backup personal settings
        signatures
          Do not backup registred signatures

  OTHERS
    -h
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
    log_debug "Get members of the list <${email}>"
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
_account_to_backup=
_exclude_admins=false
_exclude_domains=false
_exclude_lists=false
_exclude_data=false
_exclude_filters=false
_exclude_settings=false
_exclude_signatures=false


###############
### OPTIONS ###
###############

while getopts 'm:s:p:u:g:b:e:h' opt; do
  case "${opt}" in
    m) _account_to_backup="${OPTARG}" ;;
    s) _backups_nobackup_paths="${OPTARG}" ;;
    p) _zimbra_main_path="${OPTARG}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    g) _zimbra_group="${OPTARG}" ;;
    b) _backups_path="${OPTARG}" ;;
    e) case "${OPTARG}" in
         admins) _exclude_admins=true ;;
         domains) _exclude_domains=true ;;
         lists) _exclude_lists=true ;;
         data) _exclude_data=true ;;
         filters) _exclude_filters=true ;;
         settings) _exclude_settings=true ;;
         signatures) _exclude_signatures=true ;;
         *) log_err "Value <${OPTARG}> not supported by option -e"; show_usage ;;
       esac ;;
    h) show_usage ;;
    \?) exit_usage ;;
  esac
done

if ! [ -r "${_zimbra_main_path}" ]; then
  log_err "Zimbra path <${_zimbra_main_path}> doesn't exist or is not readable"
  exit 1
fi

if ! [ -w "${_backups_path}" ]; then
  log_err "Backups path <${_backups_path}> doesn't exist or is not writable"
  exit 1
fi


##############
### SCRIPT ###
##############

trap 'trap_exit_error $LINENO' ERR
trap trap_cleaning INT

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
    log_warn "Skipping <${email}> account (folder already exists)"
  else

    ${_exclude_settings} || {
      log_info "Backuping settings from <${email}>"
      zimbraBackupAccountSettings "${email}"
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

log_info "Backup done!"

exit 0
