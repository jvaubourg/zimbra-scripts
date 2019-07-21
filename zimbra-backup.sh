#!/bin/bash
# Julien Vaubourg <ju.vg>
# CC-BY-SA (2019)
# https://github.com/jvaubourg/zimbra-scripts

#############
## HELPERS ##
#############

source ./zimbra-helpers.sh.inc

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
      Path of a folder to skip when backuping data from accounts (can be a POSIX BRE regex for grep between ^ and $)
      Repeat this option as many times as necessary to exclude different kind of folders
      [Default] No exclusion
      [Example] -s /Briefcase/movies -s '/Inbox/list-.*' -s '.*/nobackup'

    -l
      Lock the accounts just before starting to backup them
      Locks are NOT removed after the backup: useful when reinstalling the server
      [Default] Not locked

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


####################
## CORE FUNCTIONS ##
####################

function cleanFailedProcess() {
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

# Usable after zimbraBackupAccountSettings
function extractFromAccountSettingsFile() {
  local email="${1}"
  local field="${2}"
  local settings_file="${_backups_path}/accounts/${email}/settings"
  local value=$((grep "^${field}:" "${settings_file}" || true) | sed "s/^${field}: //")

  printf '%s' "${value}"
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
  
    if [ ! -z "${exclude_accounts}" ]; then
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

function selectAccountDataPathsToExclude() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/excluded_data_paths"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"
  touch "${backup_file}"

  if [ "${#_backups_exclude_data_regexes[@]}" -gt 0 ]; then
    local folders=$(zimbraGetAccountFoldersList "${email}")
  
    for regex in "${_backups_exclude_data_regexes[@]}"; do
      local selected_folders=$(printf '%s' "${folders}" | (grep -- "^${regex}\$" || true))

      if [ ! -z "${selected_folders}" ]; then
        log_debug "${email}: Raw list of the folders selected to be excluded: $(echo ${selected_folders})"

        if [ "$(printf '%s' "${selected_folders}" | wc -l)" -gt 1 ]; then

          # We need to be sure that some selected folders are not included in other ones
          while [ ! -z "${selected_folders}" ]; do
            local first=$(printf '%s' "${selected_folders}" | head -n 1)
            local first_escaped=$(escapeGrepStringRegexChars "${first}")

            # The list of folders is sorted by Zimbra so the first path cannot be included in another one
            log_debug "${email}: Data folder <${first}> will not be backuped"
            printf '%s\n' "${first}" >> "${backup_file}"

            # Remove the saved folder and all of its subfolders from the selection and start again with the parent loop
            selected_folders=$(printf '%s' "${selected_folders}" | (grep -v -- "^${first_escaped}\\(\$\\|/\\)" || true))
          done
        else
          log_debug "${email}: Data folder <${selected_folders}> will not be backuped"
          printf '%s\n' "${selected_folders}" > "${backup_file}"
        fi
      fi
    done
  fi
}

function getAccountExcludeDataSize() {
  local email="${1}"
  local exclude_paths="${2}"
  local total_size_bytes=0
  local total_size_human=

  for path in ${exclude_paths}; do
    local size_attributes=$(zimbraGetFolderAttributes "${email}" "${path}" | grep '^\s\+"size":')
    local size_bytes=$(printf '%s' "${size_attributes}" | sed 's/^.*:\s\+\([0-9]\+\).*$/\1/' | paste -sd+ | bc)
    total_size_bytes=$(( total_size_bytes + size_bytes ))
  done

  total_size_human=$(numfmt --to=iec --suffix=B "${total_size_bytes}")

  printf '%s' "${total_size_human}"
}

function getAccountIncludeDataSize() {
  local email="${1}"
  local exclude_size_human="${2}"

  local exclude_size_bytes=$(numfmt --from=iec --suffix=B "${exclude_size_human}" | tr -d B)
  local data_size_bytes=$(zimbraGetAccountDataSize "${email}" | numfmt --from=iec --suffix=B | tr -d B)
  local include_size_human=$(numfmt --to=iec --suffix=B "$(( data_size_bytes - exclude_size_bytes ))")

  printf '%s' "${include_size_human}"
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
    zimbraGetListMembers "${list_email}" | (grep -F @ | grep -v '^#' || true) > "${backup_file}"
  done
}

function zimbraBackupAccountLock() {
  local email="${1}"

  zimbraSetAccountLock "${email}" true
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
  find "${backup_path}" -mindepth 1 | while read tmp_backup_file
  do
    local extension='txt'

    # Save the name of the signature from the Zimbra field
    local name=$((grep '^zimbraSignatureName: ' "${tmp_backup_file}" || true) | sed 's/^zimbraSignatureName: //')

    # A signature with no name is possible with older versions of Zimbra
    if [ -z "${name}" ]; then
      log_warn "${email}: One signature not saved (no name)"
    else

      # A field zimbraPrefMailSignatureHTML instead of zimbraPrefMailSignature means an HTML signature
      if grep -Fq zimbraPrefMailSignatureHTML "${tmp_backup_file}"; then
        extension=html
      fi

      # Remove the field name prefixing the signature
      sed 's/zimbraPrefMailSignature\(HTML\)\?: //' -i "${tmp_backup_file}"

      # Save the name of the signature in the first line
      # Rename the file to indicate if the signature is html or plain text
      local backup_file="${tmp_backup_file}.${extension}"
      printf '%s' "${name}" > "${backup_file}"

      # Remove every line corresponding to a Zimbra field and not the signature content itself
      (grep -iv '^zimbra[a-z]\+: ' "${tmp_backup_file}" || true) >> "${backup_file}"

      # Remove the last empty line
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
  local backup_data_size=0B
  local filter_query=

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  selectAccountDataPathsToExclude "${email}"

  if [ -s "${backup_path}/excluded_data_paths" ]; then
    log_debug "${email}: Calculate size of the data to backup"

    local exclude_paths=$(cat "${backup_path}/excluded_data_paths")
    local exclude_paths_count=$(wc -l "${backup_path}/excluded_data_paths" | awk '{ print $1 }')
    local exclude_data_size=$(getAccountExcludeDataSize "${email}" "${exclude_paths}")
    backup_data_size=$(getAccountIncludeDataSize "${email}" "${exclude_data_size}")

    while read path; do
      local escaped_path="${path//\"/\\\"}"
      filter_query="${filter_query} and not under:\"${escaped_path}\""
    done < "${backup_path}/excluded_data_paths"

    log_info "${email}: ${exclude_data_size} of data are going to be excluded (${exclude_paths_count} folders)"
  else
    log_debug "${email}: Calculate size of the data (nothing to exclude)"
    backup_data_size=$(zimbraGetAccountDataSize "${email}")
  fi

  if [ ! -z "${filter_query}" ]; then
    filter_query="&query=${filter_query/ and /}"
    log_debug "${email}: Data filter query is <${filter_query}>"
  fi

  log_info "${email}: ${backup_data_size} of data are going to be backuped"
  zimbraGetAccountData "${email}" "${filter_query}" > "${backup_file}"
}


########################
### GLOBAL VARIABLES ###
########################

_backups_include_accounts=
_backups_exclude_accounts=
_backups_lock_accounts=false
_exclude_admins=false
_exclude_domains=false
_exclude_lists=false
_exclude_settings=false
_exclude_aliases=false
_exclude_signatures=false
_exclude_filters=false
_exclude_data=false
_accounts_to_backup=
_backuping_account=

# Using an array prevents issues with spaces in regexes
declare -a _backups_exclude_data_regexes


###############
### OPTIONS ###
###############

while getopts 'm:x:s:lb:p:u:g:e:d:h' opt; do
  case "${opt}" in
    m) _backups_include_accounts=$(echo -En ${_backups_include_accounts} ${OPTARG}) ;;
    x) _backups_exclude_accounts=$(echo -En ${_backups_exclude_accounts} ${OPTARG}) ;;
    s) _backups_exclude_data_regexes+=("${OPTARG%/}") ;;
    l) _backups_lock_accounts=true ;;
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

if [ ! -d "${_zimbra_main_path}" -o ! -x "${_zimbra_main_path}" ]; then
  log_err "Zimbra path <${_zimbra_main_path}> doesn't exist, is not a directory or is not executable"
  exit 1
fi

if [ ! -d "${_backups_path}" -o ! -x "${_backups_path}" -o ! -w "${_backups_path}" ]; then
  log_err "Backups path <${_backups_path}> doesn't exist, is not a directory or is not writable"
  exit 1
fi


###################
### MAIN SCRIPT ###
###################

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

if [ -z "${_backups_include_accounts}" ]; then
  log_info "Preparing accounts backuping"
fi

_accounts_to_backup=$(selectAccountsToBackup "${_backups_include_accounts}" "${_backups_exclude_accounts}")

if [ -z "${_accounts_to_backup}" ]; then
  log_debug "No account to backup"
else
  log_debug "Accounts to backup: ${_accounts_to_backup}"

  # Backup accounts
  for email in ${_accounts_to_backup}; do
    if [ -e "${_backups_path}/accounts/${email}" ]; then
      log_warn "Skip account <${email}> (<${_backups_path}/accounts/${email}/> already exists)"
    else
      resetAccountProcessDuration

      _backuping_account="${email}"
      log_info "Backuping account <${email}>"

      ${_backups_lock_accounts} && {
        log_info "${email}: Locking the account"
        zimbraBackupAccountLock "${email}"
      }
  
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
        log_info "${email}: Backuping data"
        zimbraBackupAccountData "${email}"
      }
  
      showAccountProcessDuration
      _backuping_account=
    fi
  done
fi

setZimbraPermissions "${_backups_path}"
showFullProcessDuration

exit 0
