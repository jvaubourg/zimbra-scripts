# Julien Vaubourg <ju.vg>
# CC-BY-SA (2019)
# https://github.com/jvaubourg/zimbra-scripts


#############
## HELPERS ##
#############

function log() { printf '%s| [%s]%s\n' "$(date +'%F %T')" "${_log_id}" "${1}"; }
function log_debug() { ([ "${_debug_mode}" -ge 1 ] && log "[DEBUG] ${1}" >&2) || true; }
function log_info() { log "[INFO] ${1}"; }
function log_warn() { log "[WARN] ${1}" >&2; }
function log_err() { log "[ERR] ${1}" >&2; }

function resetAccountProcessDuration() {
  _process_timer="${SECONDS}"
}

function showAccountProcessDuration {
  local duration_secs=$(( SECONDS - _process_timer ))
  local duration_fancy=$(date -ud "0 ${duration_secs} seconds" +%T)

  log_info "Time used for processing this account: ${duration_fancy}"
}

function showFullProcessDuration {
  local duration_fancy=$(date -ud "0 ${SECONDS} seconds" +%T)

  log_info "Time used for processing everything: ${duration_fancy}"
}

function escapeGrepStringRegexChars() {
  local search="${1}"
  printf '%s' "$(printf '%s' "${search}" | sed 's/[.[\*^$]/\\&/g')"
}

function setZimbraPermissions() {
  local folder="${1}"

  chown -R "${_zimbra_user}:${_zimbra_group}" "${folder}"
}


########################
### GLOBAL VARIABLES ###
########################

# Default values (can be changed with parent script options)
_log_id=UNKNOWN
_backups_path=/tmp/zimbra_backups
_zimbra_main_path=/opt/zimbra
_zimbra_user=zimbra
_zimbra_group=zimbra
_existing_accounts=
_process_timer=
_debug_mode=0


######################
### CORE FUNCTIONS ###
######################

# Return a list of email accounts to backup, depending on the include/exclude lists
# Used by zimbra-backup and zimbra-borg-backup
function selectAccountsToBackup() {
  local include_accounts="${1}"
  local exclude_accounts="${2}"
  local accounts_to_backup="${include_accounts}"

  # Backup either accounts provided with -m, either all accounts,
  # either all accounts minus the ones provided with -x
  if [ -z "${accounts_to_backup}" ]; then
    accounts_to_backup=$(zimbraGetAccounts || true)
    log_debug "Existing accounts: ${accounts_to_backup}"

    if [ -n "${exclude_accounts}" ]; then
      accounts=

      for email in ${accounts_to_backup}; do
        if [[ ! "${exclude_accounts}" =~ (^| )"${email}"($| ) ]]; then
          accounts="${accounts} ${email}"
        fi
      done

      accounts_to_backup="${accounts}"
    fi
  fi

  # echo is used to remove extra spaces
  echo -En ${accounts_to_backup}
}

# Return a list of email accounts to restore, depending on the include/exclude lists
# Used by zimbra-restore and zimbra-borg-restore
function selectAccountsToRestore() {
  local include_accounts="${1}"
  local exclude_accounts="${2}"
  local accounts_to_restore="${include_accounts}"

  # Restore either accounts provided with -m, either all accounts,
  # either all accounts minus the ones provided with -x
  if [ -z "${accounts_to_restore}" ]; then
    accounts_to_restore=$(ls "${_backups_path}/accounts")

    if [ -n "${exclude_accounts}" ]; then
      accounts=

      for email in ${accounts_to_restore}; do
        if [[ ! "${exclude_accounts}" =~ (^| )"${email}"($| ) ]]; then
          accounts="${accounts} ${email}"
        fi
      done

      accounts_to_restore="${accounts}"
    fi
  fi

  # echo is used to remove extra spaces
  echo -En ${accounts_to_restore}
}
