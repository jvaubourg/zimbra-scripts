# zimbra-scripts

WIP - Not ready to use

Clone me into */usr/share/zimbra-scripts/* and do symbolic links for the .sh files to */usr/bin/local/*.

**Remote: Host key verification failed.**: As root, always do a first SSH connection from the mail server to all the Borg servers to use, to validate yourself the host keys.

## Backup
### Locally using zimbra-backup.sh

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

### Remotly using zimbra-borg-backup.sh

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
        [Default] /opt/zimbra
  
      -u user
        Zimbra UNIX user
        [Default] zimbra
  
      -g group
        Zimbra UNIX group
        [Default] zimbra
  
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
        [Default] 22
  
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
  
          zimbra-borg-backup.sh\
            -a mailbackup@mybackups.example.com:main\
            -z 'JRX2jVkRDpH6+OQ9hw/7sWn4F0OBps42I2TQ6DvRIgI='\
            -k /root/borg/sshkey.priv\
            -t 2222\
            -r mailbackup@mybackups.example.com:users/
  
      (2) Backup only the account jdoe@example.com, not the other ones
          If there is a Backup Config File named jdoe@example.com already existing,
          the Borg server described in it will be used. Otherwise, it will be backuped
          on mybackups.example.com (using sshkey.priv and port 2222) in users/<hash>,
          and a Backup Config File will be created in /opt/zimbra_borgackup/configs/
  
          zimbra-borg-backup.sh\
            -a mailbackup@mybackups.example.com:main\
            -z 'JRX2jVkRDpH6+OQ9hw/7sWn4F0OBps42I2TQ6DvRIgI='\
            -k /root/borg/sshkey.priv\
            -t 2222\
            -r mailbackup@mybackups.example.com:users/\
            -m jdoe@example.com

## Restore
### Locally using zimbra-restore.sh

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

### Remotly using zimbra-borg-restore.sh

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
        [Default] /opt/zimbra
  
      -u user
        Zimbra UNIX user
        [Default] zimbra
  
      -g group
        Zimbra UNIX group
        [Default] zimbra
  
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
        [Default] 22
  
      -k path
        Path to the SSH private key to use to connect to all remote servers (see -a and Backup Config Files)
        This SSH key has to be configured without any passphrase
        [Default] 
  
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
  
          zimbra-borg-restore.sh\
            -a borg@testrestore.choca.pics:main\
            -z 'JRX2jVkRDpH6+OQ9hw/7sWn4F0OBps42I2TQ6DvRIgI='\
            -k /root/borg/sshkey.priv\
            -t 2222
  
      (2) Restore only the account jdoe@example.com (who is not existing anymore in Zimbra) but
          not the other ones
  
          zimbra-borg-restore.sh\
            -a borg@testrestore.choca.pics:main\
            -z 'JRX2jVkRDpH6+OQ9hw/7sWn4F0OBps42I2TQ6DvRIgI='\
            -k /root/borg/sshkey.priv\
            -t 2222\
            -m jdoe@example.com

## Backup's Anatomy

### Without using Borg

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

### Using Borg

Main repository:

    server/domains/example.com
    server/domains/example.org
    server/domains/example.org/dkim_info
    server/lists/foobars@example.com
    server/lists/foobars@example.com/members
    server/lists/foobars@example.com/aliases
    borg/configs/foo@example.com
    borg/configs/bar@example.org
    backup_info/command_line
    backup_info/date
    backup_info/zimbra_version
    backup_info/centos_version
    backup_info/scripts
    backup_info/scripts/zimbra-backup.sh
    backup_info/scripts/zimbra-restore.sh

Account repository:

    settings/all_settings
    settings/identity/cn
    settings/identity/givenName
    settings/identity/displayName
    settings/identity/userPassword
    settings/aliases
    settings/signatures/1.txt
    settings/signatures/2.html
    settings/others/001-zimbraMailSieveScript
    settings/others/002-zimbraFeatureOutOfOfficeReplyEnabled
    settings/others/003-zimbraPrefOutOfOfficeCacheDuration
    settings/others/004-zimbraPrefOutOfOfficeStatusAlertOnLogin
    data/excluded_data_paths_full
    data/excluded_data_paths
    data/data.tar
    backup_info/command_line
    backup_info/date
    backup_info/zimbra_version
    backup_info/centos_version
    backup_info/scripts
    backup_info/scripts/zimbra-backup.sh
    backup_info/scripts/zimbra-restore.sh
