# Remote backup and restore

Remote backup and restore of Zimbra accounts and settings, using Borgbackup and scripts with a lot of options.

## Install

Clone me into */usr/share/zimbra-scripts/* and do symbolic links for the .sh files to */usr/bin/local/*.

Or use install scripts located in ../install/.

**Remote: Host key verification failed.**: As root, always do a first SSH connection from the mail server to all the Borg servers to use, to validate yourself the host keys.

## Backup with zimbra-borg-backup.sh

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

## Restore with zimbra-borg-restore.sh

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
            -a mailbackup@mybackups.example.com:main\
            -z 'JRX2jVkRDpH6+OQ9hw/7sWn4F0OBps42I2TQ6DvRIgI='\
            -k /root/borg/sshkey.priv\
            -t 2222
  
      (2) Restore only the account jdoe@example.com (who is not existing anymore in Zimbra) but
          not the other ones
  
          zimbra-borg-restore.sh\
            -a mailbackup@mybackups.example.com:main\
            -z 'JRX2jVkRDpH6+OQ9hw/7sWn4F0OBps42I2TQ6DvRIgI='\
            -k /root/borg/sshkey.priv\
            -t 2222\
            -m jdoe@example.com

## Backup's Anatomy

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

    accounts/foo@example.com/settings/all_settings
    accounts/foo@example.com/settings/identity/cn
    accounts/foo@example.com/settings/identity/givenName
    accounts/foo@example.com/settings/identity/displayName
    accounts/foo@example.com/settings/identity/userPassword
    accounts/foo@example.com/settings/aliases
    accounts/foo@example.com/settings/signatures/1.txt
    accounts/foo@example.com/settings/signatures/2.html
    accounts/foo@example.com/settings/pref/zimbraPrefAccountTreeOpen
    accounts/foo@example.com/settings/pref/zimbraPrefAdminConsoleWarnOnExit
    accounts/foo@example.com/settings/pref/zimbraPrefAdvancedClientEnforceMinDisplay
    ...
    accounts/foo@example.com/settings/misc/001-zimbraFeatureMAPIConnectorEnabled
    accounts/foo@example.com/settings/misc/002-zimbraFeatureMobileSyncEnabled
    accounts/foo@example.com/settings/misc/003-zimbraArchiveEnabled
    ...
    accounts/foo@example.com/data/excluded_data_paths_full
    accounts/foo@example.com/data/excluded_data_paths
    accounts/foo@example.com/data/data.tar
    backup_info/command_line
    backup_info/date
    backup_info/zimbra_version
    backup_info/centos_version
    backup_info/scripts/zimbra-backup.sh
    backup_info/scripts/zimbra-restore.sh

## Output Examples

Borg-backup of only one account:

    # zimbra-borg-backup.sh -a mailbackup@mybackups.example.com:main -z 'JRX2jVkRDpH6+OQ9hw/7sWn4F0OBps42I2TQ6DvRIgI=' -r borg@testrestore.choca.pics: -k /root/borg/sshkey -t 2222 -m foo@example.com
    
    
    2019-12-15 19:03:55| [BORG-BACKUP][INFO] Backuping server-side settings and Backup Config Files
    2019-12-15 19:04:05| [BORG-BACKUP][INFO] Backuping using zimbra-backup.sh
    2019-12-15 19:04:05| [ZIMBRA-BACKUP][INFO] Server/Settings: Backuping admins list
    2019-12-15 19:04:05| [ZIMBRA-BACKUP][INFO] Server/Settings: Backuping domains
    2019-12-15 19:04:05| [ZIMBRA-BACKUP][INFO] Server/Settings: Backuping DKIM keys
    2019-12-15 19:04:11| [ZIMBRA-BACKUP][INFO] Server/Settings: Backuping mailing lists
    2019-12-15 19:04:14| [ZIMBRA-BACKUP][INFO] Time used for processing everything: 00:00:09
    2019-12-15 19:04:14| [BORG-BACKUP][INFO] Sending data to Borg (new archive 2019-12-15 in the main repo)
    2019-12-15 19:04:20| [BORG-BACKUP][INFO] Backuping account <foo@example.com>
    2019-12-15 19:04:34| [BORG-BACKUP][INFO] foo@example.com: Backuping using zimbra-backup.sh
    2019-12-15 19:04:34| [ZIMBRA-BACKUP][INFO] foo@example.com: Backuping settings
    2019-12-15 19:04:34| [ZIMBRA-BACKUP][INFO] foo@example.com/Settings: Backuping raw settings file
    2019-12-15 19:04:34| [ZIMBRA-BACKUP][INFO] foo@example.com/Settings: Backuping identity-related settings
    2019-12-15 19:04:34| [ZIMBRA-BACKUP][INFO] foo@example.com/Settings: Backuping aliases
    2019-12-15 19:04:35| [ZIMBRA-BACKUP][INFO] foo@example.com/Settings: Backuping signatures
    2019-12-15 19:04:35| [ZIMBRA-BACKUP][INFO] foo@example.com/Settings: Backuping pref settings
    2019-12-15 19:04:39| [ZIMBRA-BACKUP][INFO] foo@example.com/Settings: Backuping misc settings
    2019-12-15 19:04:40| [ZIMBRA-BACKUP][INFO] foo@example.com: Backuping data
    2019-12-15 19:04:47| [ZIMBRA-BACKUP][INFO] foo@example.com/Data: 13MB will be excluded (2 folders)
    2019-12-15 19:04:47| [ZIMBRA-BACKUP][INFO] foo@example.com/Data: 611MB are going to be backuped
    2019-12-15 19:05:25| [ZIMBRA-BACKUP][INFO] Time used for processing this account: 00:00:51
    2019-12-15 19:05:28| [ZIMBRA-BACKUP][INFO] Time used for processing everything: 00:00:54
    2019-12-15 19:05:28| [BORG-BACKUP][INFO] foo@example.com: Sending data to Borg (new archive 2019-12-15 in the account repo)
    ------------------------------------------------------------------------------
    Archive name: 2019-12-15
    Archive fingerprint: c177dec1b38dd252ed30b34e9e17c52b79eabbe9802a70fffba1763d4faadb91
    Time (start): Sun, 2019-12-15 19:05:32
    Time (end):   Sun, 2019-12-15 19:05:50
    Duration: 18.09 seconds
    Number of files: 189
    Utilization of max. archive size: 0%
    ------------------------------------------------------------------------------
                           Original size      Compressed size    Deduplicated size
    This archive:              624.18 MB            588.34 MB            129.64 MB
    All archives:                1.26 GB              1.19 GB            690.42 MB
    
                           Unique chunks         Total chunks
    Chunk index:                     345                  854
    ------------------------------------------------------------------------------
    2019-12-15 19:05:51| [BORG-BACKUP][INFO] Time used for processing this account: 00:01:31
    2019-12-15 19:05:51| [BORG-BACKUP][INFO] Time used for processing everything: 00:01:56

Borg-restore of only one account:

    # zimbra-borg-restore.sh -a mailbackup@mybackups.example.com:main -z 'JRX2jVkRDpH6+OQ9hw/7sWn4F0OBps42I2TQ6DvRIgI=' -k /root/borg/sshkey -t 2222 -e -r -m foo@example.com
    2019-08-19 22:53:49| [BORG-RESTORE][INFO] Mounting and copying files from the main repository
    2019-08-19 22:54:00| [BORG-RESTORE][INFO] Archive 2019-08-19 is used
    2019-08-19 22:54:09| [BORG-RESTORE][INFO] Restoring account <foo@example.com>
    2019-08-19 22:54:18| [BORG-RESTORE][INFO] foo@example.com: Archive 2019-08-19 is used
    2019-08-19 22:54:18| [BORG-RESTORE][INFO] foo@example.com: Restoring using zimbra-restore.sh
    2019-08-19 22:54:18| [ZIMBRA-RESTORE][INFO] Getting Zimbra main domain
    2019-08-19 22:54:20| [ZIMBRA-RESTORE][INFO] foo@example.com: Creating account
    2019-08-19 22:54:20| [ZIMBRA-RESTORE][INFO] foo@example.com: New password is cd5c7c348de03c284528
    2019-08-19 22:54:20| [ZIMBRA-RESTORE][INFO] foo@example.com: Force user to change the password next time they log in
    2019-08-19 22:54:20| [ZIMBRA-RESTORE][INFO] foo@example.com: Restoring account
    2019-08-19 22:54:20| [ZIMBRA-RESTORE][INFO] foo@example.com: Locking for the time of the restoration
    2019-08-19 22:54:20| [ZIMBRA-RESTORE][INFO] foo@example.com: Restoring settings
    2019-08-19 22:54:20| [ZIMBRA-RESTORE][INFO] foo@example.com/Settings: Restoring aliases
    2019-08-19 22:54:21| [ZIMBRA-RESTORE][INFO] foo@example.com/Settings: Restoring signatures
    2019-08-19 22:54:21| [ZIMBRA-RESTORE][INFO] foo@example.com/Settings: Restoring other settings
    2019-08-19 22:54:22| [ZIMBRA-RESTORE][INFO] foo@example.com: Restoring data (2.6GB compressed)
    2019-08-19 23:06:21| [ZIMBRA-RESTORE][INFO] foo@example.com: Unlocking
    2019-08-19 23:06:21| [ZIMBRA-RESTORE][INFO] Time used for processing this account: 00:12:01
    2019-08-19 23:06:21| [ZIMBRA-RESTORE][INFO] Time used for processing everything: 00:12:03
