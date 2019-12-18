# Julien Vaubourg <ju.vg>
# CC-BY-SA (2019)
# https://github.com/jvaubourg/zimbra-scripts

source /usr/share/zimbra-scripts/lib/zimbra-exec.inc.sh


###############
### HELPERS ###
###############

# Hides IDs returned by Zimbra when creating an object
# (Zimbra sometimes displays errors directly to stdout)
function hideReturnedId() {
  grep -v '^[a-f0-9-]\+$' || true
}


######################
## ZIMBRA CLI & API ##
######################

##
## GETTERS
##

function zimbraGetMainDomain() {
  local cmd=(fastzmprov getConfig zimbraDefaultDomainName)

  execZimbraCmd cmd | sed 's/^zimbraDefaultDomainName: //'
}

function zimbraGetAdminAccounts() {
  local cmd=(fastzmprov getAllAdminAccounts)

  execZimbraCmd cmd
}

function zimbraGetDomains() {
  local cmd=(fastzmprov getAllDomains)

  execZimbraCmd cmd
}

function zimbraGetDkimInfo() {
  local domain="${1}"
  local cmd=("${_zimbra_main_path}/libexec/zmdkimkeyutil" -q -d "${domain}")

  execZimbraCmd cmd 2> /dev/null || true
}

function zimbraGetLists() {
  local cmd=(fastzmprov getAllDistributionLists)

  execZimbraCmd cmd
}

function zimbraGetListMembers() {
  local list_email="${1}"
  local cmd=(fastzmprov getDistributionListMembership "${list_email}")

  execZimbraCmd cmd
}

function zimbraGetListAliases() {
  local list_email="${1}"
  local cmd=(fastzmprov getDistributionList "${list_email}" zimbraMailAlias)

  execZimbraCmd cmd | awk '/^zimbraMailAlias:/ { print $2 }'
}

function zimbraGetAccounts() {
  local cmd=(fastzmprov getAllAccounts)

  # echo is used to remove return chars
  echo -En $(execZimbraCmd cmd | (grep -vE '^(spam\.|ham\.|virus-quarantine\.|galsync[.@])' || true))
}

function zimbraGetAccountSetting() {
  local email="${1}"
  local field="${2}"
  local cmd=(fastzmprov getAccount "${email}" "${field}")

  execZimbraCmd cmd | sed "1d;\$d;s/^${field}: //"
}

function zimbraGetAccountAliases() {
  local email="${1}"

  zimbraGetAccountSetting "${email}" zimbraMailAlias
}

function zimbraGetAccountSignatures() {
  local email="${1}"
  local cmd=(fastzmprov getSignatures "${email}")

  execZimbraCmd cmd
}

function zimbraGetAccountSettingsFile() {
  local email="${1}"
  local cmd=(fastzmprov getAccount "${email}")

  execZimbraCmd cmd
}

function zimbraGetAccountFoldersList() {
  local email="${1}"
  zmmailboxSelectMailbox "${email}"

  local cmd=(fastzmmailbox getAllFolders)
  execZimbraCmd cmd | awk '/\// { print $5 }'
}

function zimbraGetAccountDataSize() {
  local email="${1}"
  zmmailboxSelectMailbox "${email}"

  local cmd=(fastzmmailbox getMailboxSize)
  execZimbraCmd cmd | tr -d ' '
}

function zimbraGetAccountData() {
  local email="${1}"
  local filter_query="${2}"
  local cmd=(zmmailbox --zadmin --mailbox "${email}" getRestURL "//?fmt=tar${filter_query}")

  execZimbraCmd cmd
}

function zimbraGetFolderAttributes() {
  local email="${1}"
  zmmailboxSelectMailbox "${email}"

  local path="${2}"
  local cmd=(fastzmmailbox getFolder "${path}")
  execZimbraCmd cmd
}

function zimbraIsAccountExisting() {
  local email="${1}"

  if [ -z "${_existing_accounts}" ]; then
    _existing_accounts=$(zimbraGetAccounts || true)
    log_debug "Already existing accounts: ${_existing_accounts}"
  fi

  [[ "${_existing_accounts}" =~ (^| )"${email}"($| ) ]]
}

function zimbraGetVersion() {
  local cmd=(zmcontrol -v)

  execZimbraCmd cmd
}


##
## SETTERS
##

function zimbraCreateDomain() {
  local domain="${1}"
  local cmd=(fastzmprov createDomain "${domain}" zimbraAuthMech zimbra)

  execZimbraCmd cmd | hideReturnedId
}

function zimbraCreateDkim() {
  local domain="${1}"
  local cmd=("${_zimbra_main_path}/libexec/zmdkimkeyutil" -a -d "${domain}")

  execZimbraCmd cmd | (grep -v '^\(DKIM Data added\|Public signature to\)' || true)
}

function zimbraCreateList() {
  local list_email="${1}"
  local cmd=(fastzmprov createDistributionList "${list_email}")

  execZimbraCmd cmd | hideReturnedId
}

function zimbraSetListMember() {
  local list_email="${1}"
  local member_email="${2}"
  local cmd=(fastzmprov addDistributionListMember "${list_email}" "${member_email}")

  execZimbraCmd cmd
}

function zimbraSetListAlias() {
  local list_email="${1}"
  local alias_email="${2}"
  local cmd=(fastzmprov addDistributionListAlias "${list_email}" "${alias_email}")

  execZimbraCmd cmd
}

function zimbraCreateAccount() {
  local email="${1}"
  local cn="${2}"
  local givenName="${3:-${cn}}"
  local displayName="${4:-${cn}}"
  local password="${5}"
  local cmd=(fastzmprov createAccount "${email}" "${password}" cn "${cn}" displayName "${displayName}" givenName "${givenName}" zimbraPrefFromDisplay "${displayName}")

  execZimbraCmd cmd | hideReturnedId
}

function zimbraUpdateAccountPassword() {
  local email="${1}"
  local hash_password="${2}"
  local cmd=(fastzmprov modifyAccount "${email}" userPassword "${hash_password}")

  execZimbraCmd cmd
}

function zimbraSetPasswordMustChange() {
  local email="${1}"
  local cmd=(fastzmprov modifyAccount "${email}" zimbraPasswordMustChange TRUE)

  execZimbraCmd cmd
}

function zimbraRemoveAccount() {
  local email="${1}"
  local cmd=(zmprov deleteAccount "${email}")

  execZimbraCmd cmd
}

function zimbraSetAccountLock() {
  local email="${1}"
  local lock="${2}"
  local status=active
  local cmd=

  # The maintenance status would be more appropriate but it doesn't enable to use zmmmailbox commands
  # (ERROR: service.AUTH_EXPIRED)
  if ${lock}; then
    status=locked
  fi

  # The fast prompt is not used here because the SOAP config is not correctly updated when modified
  # with LDAP provisionning... it looks like a bug in Zimbra
  # https://bugzilla.zimbra.com/show_bug.cgi?id=109270
  cmd=(zmprov modifyAccount "${email}" zimbraAccountStatus "${status}")

  execZimbraCmd cmd
}

function zimbraSetAccountAlias() {
  local email="${1}"
  local alias="${2}"
  local cmd=(fastzmprov addAccountAlias "${email}" "${alias}")

  execZimbraCmd cmd
}

function zimbraSetAccountSignature() {
  local email="${1}"
  local name="${2}"
  local type="${3}"
  local content="${4}"
  local field=zimbraPrefMailSignature
  local cmd=

  if [ "${type}" = html ]; then
    field=zimbraPrefMailSignatureHTML
  fi

  cmd=(fastzmprov createSignature "${email}" "${name}" "${field}" "${content}")
  execZimbraCmd cmd | hideReturnedId
}

function zimbraSetAccountSetting() {
  local email="${1}"
  local field="${2}"
  local value="${3}"
  local cmd=(fastzmprov modifyAccount "${email}" "${field}" "${value}")

  execZimbraCmd cmd
}

function zimbraSetAccountData() {
  local email="${1}"
  local backup_file="${2}"

  # The skip resolve method is a bit slower than reset but it enables to not drop incoming mails during the restoration process
  local cmd=(zmmailbox --zadmin --mailbox "${email}" -t 0 postRestURL --url https://localhost:8443 '/?fmt=tar&resolve=skip' "${backup_file}")

  execZimbraCmd cmd
}

function zimbraCreateDataFolder() {
  local email="${1}"
  zmmailboxSelectMailbox "${email}"

  local folder="${2}"
  local cmd=(fastzmmailbox createFolder "${folder}")
  execZimbraCmd cmd | hideReturnedId
}
