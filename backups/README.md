# Local backup and restore

Local backup and restore of Zimbra accounts and settings by executing scripts with a lot of options.

## Install

Clone me into */usr/share/zimbra-scripts/* and do symbolic links for the .sh files to */usr/bin/local/*.

Or use install scripts located in ../install/.

## Backup with zimbra-backup.sh

    ACCOUNTS
      Accounts with an already existing backup folder will be skipped with a warning.
  
      -m email
        Email of an account to include in the backup
        Cannot be used with -x at the same time
        [Default] All accounts
        [Example] -m foo@example.com -m bar@example.org
        [Example] -m 'foo@example.com bar@example.org'
  
      -x email
        Email of an account to exclude of the backup
        Cannot be used with -m at the same time
        [Default] No exclusion
        [Example] -x foo@example.com -x bar@example.org
        [Example] -x 'foo@example.com bar@example.org'
  
      -s path
        Path of a folder to skip when backuping data from accounts
        (can be a POSIX BRE regex for grep between ^ and $)
        [Default] No exclusion
        [Example] -s /Briefcase/movies -s '/Inbox/list-.*' -s '.*/nobackup'
  
      -l
        Lock the accounts just before starting to backup them
        Locks are NOT removed after the backup: useful when reinstalling the server
        [Default] Not locked
  
    ENVIRONMENT
  
      -b path
        Where to save the backups
        [Default] /tmp/zimbra_backups
  
      -p path
        Main path of the Zimbra installation
        [Default] /opt/zimbra
  
      -u user
        Zimbra UNIX user
        [Default] zimbra
  
      -g group
        Zimbra UNIX group
        [Default] zimbra
  
    PARTIAL BACKUPS
  
      -i ASSET
        Do a partial backup by selecting groups of settings/data
        [Default] Everything is backuped
  
        [Example] Backup full server configuration without user data:
          -i server_settings -i accounts_settings
        [Example] Backup accounts but not the configuration of the server itself:
          -i accounts_settings -i accounts_data
  
        ASSET can be:
          server_settings
            Backup server-side settings (ie. domains, mailing lists, admins list, etc)
          accounts_settings
            Backup accounts settings (ie. identity, password, aliases, signatures, filters, etc)
          accounts_data
            Backup accounts data (ie. folders, mails, contacts, calendars, briefcase, tasks, etc)
  
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
  
      (1) Backup everything in /tmp/mybackups/
            zimbra-backup.sh -b /tmp/mybackups/
  
      (2) When backuping the mailboxes, the data inside every folder named "nobackup" will be ignored.
          Ask to your users to create an IMAP folder named "nobackup" and to put inside all their
          non-important emails (even in subfolders). Ask for the same thing but with their files in the
          Briefcase. Involve them in the issues raised by the cost of the space allocated for the backups!
            zimbra-backup.sh -b /tmp/mybackups/ -s '.*/nobackup'
  
      (3) Backup everything from the server, but only with the accounts of jdoe@example.com and jfoo@example.org
            zimbra-backup.sh -b /tmp/mybackups/ -m jdoe@example.com -m jfoo@example.org
  
      (4) Backup only the stuff related to the account of jdoe@example.com and nothing else
            zimbra-backup.sh -b /tmp/mybackups/ -i accounts_settings -i accounts_data -m jdoe@example.com

## Restore with zimbra-restore.sh

    ACCOUNTS
      Already existing accounts in Zimbra will be skipped with a warning,
      except when restoring only data (see -i)
  
      -m email
        Email of an account to include in the restore
        Cannot be used with -x at the same time
        [Default] All accounts
        [Example] -m foo@example.com -m bar@example.org
        [Example] -m 'foo@example.com bar@example.org'
  
      -x email
        Email of an account to exclude of the restore
        Cannot be used with -m at the same time
        [Default] No exclusion
        [Example] -x foo@example.com -x bar@example.org
        [Example] -x 'foo@example.com bar@example.org'
  
      -f
        Force users to change their password next time they connect after the restore
  
      -r
        Reset passwords of the restored accounts
        Automatically implies -f option
  
    ENVIRONMENT
  
      -b path
        Where the backups are
        [Default] /tmp/zimbra_backups
  
      -p path
        Main path of the Zimbra installation
        [Default] /opt/zimbra
  
      -u user
        Zimbra UNIX user
        [Default] zimbra
  
    PARTIAL BACKUPS
  
      -i ASSET
        Do a partial restore by selecting groups of settings/data
        [Default] Everything available in the backup is restored
  
        [Example] Restore full server without user data:
          -i server_settings -i accounts_settings
        [Example] Restore accounts on an already configured server:
          -i accounts_settings -i accounts_data
  
        ASSET can be:
          server_settings
            Restore server-side settings (ie. domains, mailing lists, admins list, etc)
          accounts_settings
            Restore accounts settings (ie. identity, password, aliases, signatures, filters, etc)
          accounts_data
            Restore accounts data (ie. folders, mails, contacts, calendars, briefcase, tasks, etc)
  
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
  
      (1) Restore everything from the backups saved in /tmp/mybackups/
            zimbra-restore.sh -b /tmp/mybackups/
  
      (2) Restore everything to the server, but only with the accounts of jdoe@example.com and jfoo@example.org
            zimbra-restore.sh -b /tmp/mybackups/ -m jdoe@example.com -m jfoo@example.org
  
      (3) Restore only the stuff related to the account of jdoe@example.com and nothing else
          (the domain example.com has to already exist, but not the account jdoe@example.com)
            zimbra-restore.sh -b /tmp/mybackups/ -i accounts_settings -i accounts_data -m jdoe@example.com

## Backup's Anatomy

    server/domains/example.com
    server/domains/example.com/dkim_info
    server/lists/foobars@example.com
    server/lists/foobars@example.com/members
    server/lists/foobars@example.com/aliases
    accounts/foo@example.com/settings/all_settings
    accounts/foo@example.com/settings/identity/cn
    accounts/foo@example.com/settings/identity/givenName
    accounts/foo@example.com/settings/identity/displayName
    accounts/foo@example.com/settings/identity/userPassword
    accounts/foo@example.com/settings/aliases
    accounts/foo@example.com/settings/signatures/1.txt
    accounts/foo@example.com/settings/signatures/2.html
    accounts/foo@example.com/settings/others/001-zimbraMailSieveScript
    accounts/foo@example.com/settings/others/002-zimbraFeatureOutOfOfficeReplyEnabled
    accounts/foo@example.com/settings/others/003-zimbraPrefOutOfOfficeCacheDuration
    accounts/foo@example.com/settings/others/004-zimbraPrefOutOfOfficeStatusAlertOnLogin
    accounts/foo@example.com/data/excluded_data_paths_full
    accounts/foo@example.com/data/excluded_data_paths
    accounts/foo@example.com/data/data.tar
    backup_info/command_line
    backup_info/date
    backup_info/zimbra_version
    backup_info/centos_version
    backup_info/scripts
    backup_info/scripts/zimbra-backup.sh
    backup_info/scripts/zimbra-restore.sh
