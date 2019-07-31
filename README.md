# zimbra-scripts

WIP - Not ready to use

## Backup
### Locally using zimbra-backup.sh
    
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
            accounts
              Do not backup the accounts at all
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

### Remotly using Borg with zimbra-borg-backup.sh

      ACCOUNTS
        Already existing accounts in Zimbra will be skipped with a warning.
    
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
    
        -b path
          Where the backups are
          [Default] /tmp/zimbra_backups
    
        -p path
          Main path of the Zimbra installation
          [Default] /opt/zimbra
    
        -u user
          Zimbra UNIX user
          [Default] zimbra
    
      EXCLUSIONS
    
        -e ASSET
          Do a partial restore, by excluding some settings/data
          Repeat this option as many times as necessary to exclude more than only one asset
          [Default] Everything is restored
          [Example] -e domains -e data
    
          ASSET can be:
            domains
              Do not restore domains
            lists
              Do not restore mailing lists
            aliases
              Do not restore email aliases
            signatures
              Do not restore registred signatures
            filters
              Do not restore sieve filters
            accounts
              Do not restore any accounts at all
            data
              Do not restore contents of the mailboxes (ie. folders/emails/contacts/calendar/briefcase/tasks)
            all_except_accounts
              Only restore the accounts (ie. users' settings and contents of the mailboxes)
    
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

## Restore
### Locally using zimbra-restore.sh

      ACCOUNTS
    
        -m email
          See zimbra-backup.sh -h
    
        -x email
          See zimbra-backup.sh -h
    
        -l
          See zimbra-backup.sh -h
    
        -n
          Do not backup server-related data (ie. domains, lists, etc), just accounts
          [Default] Server-related data are backuped
    
      ENVIRONMENT
    
        -c path
          Main folder dedicated to this script
          [Default] <zimbra_main_path>_borgackup (see -p)
    
          Subfolders will be:
            tmp/: Temporary backups before sending data to Borg
            configs/: See BACKUP CONFIG FILES
    
        -p path
          See zimbra-backup.sh -h
    
        -u user
          See zimbra-backup.sh -h
    
        -g group
          See zimbra-backup.sh -h
    
      MAIN BORG REPOSITORY
    
        [Mandatory] -a borg_repo
          Full Borg+SSH repository address for server-related data (ie. for everything except accounts)
          Passphrases of the repositories created for backuping the accounts will be saved in this repo
          [Example] mailbackup@mybackups.example.com:main
          [Example] mailbackup@mybackups.example.com:myrepos/main
    
        [Mandatory] -z passphrase 
          Passphrase of the Borg repository (see -a)
    
        -t port
          SSH port to reach all remote Borg servers (see -a and -r)
          [Default] 22
    
        -k path
          Path to the SSH private key to use to connect to all remote servers (see -a and -r)
          This SSH key has to be configured without any passphrase
          [Default] <main_folder>/private_ssh_key (see -c)
    
      DEFAULT BACKUP OPTIONS
        These options will be used as default when creating a new backup config file (along with -t and -k)
    
        [Mandatory] -r borg_repo
          Full Borg+SSH address where to create new repositories for the accounts
          [Example] mailbackup@mybackups.example.com:
          [Example] mailbackup@mybackups.example.com:myrepos
    
        -s path
          See zimbra-backup.sh -h
    
        -e ASSET
          See zimbra-backup.sh -h
    
          ASSET is restricted to:
            aliases
            signatures
            filters
            data
    
      BACKUP CONFIG FILES
        Every account to backup has to be associated to a config file for its backup (see -c for the folder location)
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
          See zimbra-backup.sh -h
    
        -h
          Show this help

### Remotly using Borg with zimbra-borg-restore.sh

      ACCOUNTS
    
        -m email
          See zimbra-restore.sh -h
    
        -x email
          See zimbra-restore.sh -h
    
        -f
          See zimbra-restore.sh -h
    
        -r
          See zimbra-restore.sh -h
    
        -n
          Do not restore server-related data (ie. domains, lists, etc), just accounts
          [Default] Server-related data are restored
    
      ENVIRONMENT
    
        -i date
          Date corresponding to the archive to restore, for all accounts and the main repository
          [Example] 1970-01-01
          [Default] Last archive is used
    
        -c path
          Main folder dedicated to this script
          [Default] 
    
          Subfolders will be:
            tmp/: Temporary backups before sending data to Borg
            configs/: See BACKUP CONFIG FILES
    
        -p path
          See zimbra-restore.sh -h
    
        -u user
          See zimbra-restore.sh -h
    
        -g group
          See zimbra-restore.sh -h
    
      MAIN BORG REPOSITORY
    
        [Mandatory] -a borg_repo
          Full Borg+SSH repository address for the main files
          [Example] mailbackup@mybackups.example.com:main
          [Example] mailbackup@mybackups.example.com:myrepos/main
    
        [Mandatory] -z passphrase 
          Passphrase of the Borg repository (see -a)
    
        -t port
          SSH port to reach all remote Borg servers (see -a and backup config files)
          [Default] 22
    
        -k path
          Path to the SSH private key to use to connect to all remote servers (see -a and backup config files)
          This SSH key has to be configured without any passphrase
          [Default] 
    
      BACKUP CONFIG FILES
        See zimbra-borg-backup.sh -h
    
      OTHERS
    
        -d LEVEL
          See zimbra-restore.sh -h
    
        -h
          Show this help
    
