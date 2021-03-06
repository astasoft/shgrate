#!/bin/bash
#
# @author Rio Astamal <me@rioastamal.net>
# @desc Shell script to do SQL schema migration
# @see README.md

# Script name used for logger
readonly SG_SCRIPT_NAME=$(basename $0)

SG_VERSION=1.1
SG_CONFIG_FILE=""
SG_DRY_RUN="false"
SG_ROLLBACK_MODE="false"

# Flag for debugging
[ -z "$SG_DEBUG" ] && SG_DEBUG="false"

# Migration file suffix
[ -z "$SG_MIGRATE_SUFFIX" ] && SG_MIGRATE_SUFFIX="sg_migrate.sql"

# Default log file
[ -z "$SG_LOG_FILE" ] && SG_LOG_FILE="shgrate.log"

# Environment
[ -z "$SG_ENVIRONMENT" ] && SG_ENVIRONMENT="production"

# Function to show the help message
sg_help()
{
    echo "\
Usage: $0 [OPTIONS]

Where OPTIONS:
  -a NAME       use database NAME
  -b            rollback mode
  -c FILE       read the config file from the FILE
  -e ENVIRON    specify environment name by ENVIRON. Default is 'production'
  -h            print this help and exit
  -m NAME       create a migration file named NAME
  -o FILE       save log output to the FILE
  -r            dry run
  -v            print the shgrate version

shgrate is a simple database schema migration for MySQL written in Bash.
shgrate is free software licensed under MIT. Visit the project homepage
at http://github.com/astasoft/shgrate."
}

# Function to display message to inform user to see the help
sg_see_help()
{
    echo "Try '$SG_SCRIPT_NAME -h' for more information."
}

# Try to read from the config file if specified
# We can not use sg_log and sg_err because we still does not know
# the log file
getopts ':c:' SG_CONFIG_OPT
case $SG_CONFIG_OPT in
    c)
        [ "$SG_DEBUG" = "true" ] && echo "DEBUG: Using config file ${OPTARG}."
        [ -f "$OPTARG" ] || {
            echo "ERROR: Config file $OPTARG is not found." >&2
            exit 2
        }

        source "$OPTARG"
    ;;

    \?)
        # Do nothing
    ;;
esac

# We want another getopts to parse arguments so we reset OPTIND
OPTIND=1

# Function to output syslog like output
sg_write_log()
{
    SG_LOG_MESSAGE="$@"
    SG_SYSLOG_DATE_STYLE=$( date +"%b %e %H:%M:%S" )
    SG_HOSTNAME=$( hostname )
    SG_PID=$$

    # Date Hostname AppName[PID]: MESSAGE
    printf "%s %s %s[%s]: %s\n" \
        "$SG_SYSLOG_DATE_STYLE" \
        "$SG_HOSTNAME" \
        "$SG_SCRIPT_NAME" \
        "$SG_PID" \
        "${SG_LOG_MESSAGE}">> "$SG_LOG_FILE"
}

# Function to log message
sg_log()
{
    [ "$SG_DEBUG" = "true" ] && echo "DEBUG: $@"
    sg_write_log "$@"
}

sg_err() {
    echo "ERROR: $@" >&2
    sg_write_log "$@"
    sg_see_help
}

# Function to compare files between migrated v migration directory
sg_compare_dir()
{
    # Diff will output something like:
    # ```
    # Only in tools/migrated/env_name: file_x.sql
    # Only in tools/migrations: file_y.sql
    # ```
    # We are only interest the output which says 'only in MIGRATED_DIR/ENV_NAME'
    # because it means that these files is not migrated yet.
    SG_ENV_MIGRATED_DIR="$SG_MIGRATED_DIR/$SG_ENVIRONMENT"
    diff -q "$SG_ENV_MIGRATED_DIR" "$SG_MIGRATION_DIR" | grep "^Only in $SG_MIGRATION_DIR" | \
    awk -F': ' '{print $2}' | sort
}

# Function to initialize mysql config
sg_init_mysql_config()
{
    [ -z "$SG_DB_NAME" ] && {
        sg_err "Please specify the database name in -a option, SG_DB_NAME environment or in config."
        exit 2
    }
    sg_log "Using database name ${SG_DB_NAME}."

    [ -z "$SG_CHECK_MYSQL_CONFIG_FILE" ] && SG_CHECK_MYSQL_CONFIG_FILE="false"

    # MySQL client configuration file
    [ -z "$SG_MYSQL_CONFIG_FILE" ] && SG_MYSQL_CONFIG_FILE=~/.my.cnf

    if [ "$SG_CHECK_MYSQL_CONFIG_FILE" == "true" ]; then
        [ -f "$SG_MYSQL_CONFIG_FILE" ] || {
            sg_err "Failed to find MySQL client config file ($SG_MYSQL_CONFIG_FILE)."
            exit 2
        }
    fi
    sg_log "Using MySQL client config file ${SG_MYSQL_CONFIG_FILE}."
}

# Function to initialize common config
sg_init_migrate()
{
    # Directory used to store the SQL schema migration
    [ -z "$SG_MIGRATION_DIR" ] && SG_MIGRATION_DIR="migrations"

    [ -d "$SG_MIGRATION_DIR" ] || {
        sg_err "Failed to find the migrations: $SG_MIGRATION_DIR directory."
        exit 2
    }
    sg_log "Migration directory is set to ${SG_MIGRATION_DIR}."

    [ -z "$SG_MIGRATED_DIR" ] && SG_MIGRATED_DIR="migrated"

    [ -d "$SG_MIGRATED_DIR" ] || {
        sg_err "Failed to find the migrated: $SG_MIGRATED_DIR directory."
        exit 2
    }
    sg_log "Migrated directory is set to ${SG_MIGRATED_DIR}"

    [ -z "$SG_ROLLBACK_DIR" ] && SG_ROLLBACK_DIR="rollback"

    [ -d "$SG_ROLLBACK_DIR" ] || {
        sg_err "Failed to find the rollback: $SG_ROLLBACK_DIR directory."
        exit 2
    }
    sg_log "Rollback directory is set to ${SG_ROLLBACK_DIR}."
}

# Function to create the SQL migration file
function sg_create_migration_file()
{
    local SG_DATE_RFC2822=$( date -R )
    local SG_NOW=$( date +"%Y_%m_%d_%H_%M_%S" )
    local SG_MIG_NAME=$( echo "$1" | tr '[:upper:]' '[:lower:]' )
    local SG_FILE_NAME=$( printf "%s_%s.%s" "$SG_NOW" "$SG_MIG_NAME" "$SG_MIGRATE_SUFFIX" )

    sg_init_migrate

    echo "\
-- shgrate Migration Script
-- Generated by: shgrate v${SG_VERSION}
-- File: $SG_FILE_NAME
-- Date: $SG_DATE_RFC2822
-- Write your SQL migration below this line" > "$SG_MIGRATION_DIR/$SG_FILE_NAME" || {
        sg_err "Failed to create file $SG_MIGRATION_DIR/${SG_FILE_NAME}."
        exit 2mysql --defaults-file=$SG_MYSQL_CONFIG_FILE $SG_DB_NAME < $SG_MIGRATION_DIR/$file 2>&1 >/dev/null
    }

    echo "\
-- shgrate Rollback Script
-- Generated by: shgrate v${SG_VERSION}
-- File: $SG_FILE_NAME
-- Date: $SG_DATE_RFC2822
-- Write your SQL rolllback migration below this line" > "$SG_ROLLBACK_DIR/$SG_FILE_NAME" || {
        sg_err "Failed to create file $SG_ROLLBACK_DIR/${SG_FILE_NAME}."
        exit 2
    }

    echo "Migration file: $SG_MIGRATION_DIR/${SG_FILE_NAME}."
    echo "Rollback file: $SG_ROLLBACK_DIR/${SG_FILE_NAME}."
}

# Function to migrate the schema by executing all the files in migrations
# directory which does not exists on migrated directory
sg_migrate()
{
    sg_init_mysql_config
    sg_init_migrate

    # Create the environment directory inside the migrated dir
    sg_log "Creating directory $SG_MIGRATED_DIR/$SG_ENVIRONMENT if not exists."
    mkdir -p "$SG_MIGRATED_DIR/$SG_ENVIRONMENT" 2>/dev/null || {
        sg_err "Can not create directory $SG_MIGRATED_DIR/${SG_ENVIRONMENT}."
    }

    SG_COUNTER=0
    for file in $( sg_compare_dir )
    do
        SG_COUNTER=$(( $SG_COUNTER + 1 ))

        echo -n "Migrating $file..."
        if [ "$SG_DRY_RUN" == "true" ]; then
            echo "done."
            echo ">> Contents of file $SG_MIGRATION_DIR/${file}: "
            cat "$SG_MIGRATION_DIR/$file" && echo ""

            continue
        fi

        sg_log "Running command: mysql --defaults-file=$SG_MYSQL_CONFIG_FILE $SG_DB_NAME < $SG_MIGRATION_DIR/$file 2>&1 >/dev/null"
        SG_IMPORT_ERROR="$( mysql --defaults-file=$SG_MYSQL_CONFIG_FILE $SG_DB_NAME < $SG_MIGRATION_DIR/$file 2>&1 >/dev/null )"

        if [ $? -eq 0 ]; then
            echo "done."

            # Copy the rollback content to the migrated directory
            cat "$SG_ROLLBACK_DIR/$file" > "$SG_MIGRATED_DIR/$SG_ENVIRONMENT/$file"
        else
            echo "failed."
            sg_err "Failed migrating $SG_MIGRATION_DIR/$file with message: $SG_IMPORT_ERROR"
            exit 3
        fi
    done

    [ $SG_COUNTER -eq 0 ] && echo "Nothing to migrate."
}

# Function to rollback the schema which already migrated
sg_rollback()
{
    sg_init_mysql_config
    sg_init_migrate

    sg_log "Getting list of rollback files in $SG_MIGRATED_DIR/$SG_ENVIRONMENT directory."
    SG_COUNTER=0
    for file in $( ls $SG_MIGRATED_DIR/$SG_ENVIRONMENT 2>/dev/null | sort -r | head -1 )
    do
        SG_COUNTER=$(( $SG_COUNTER + 1 ))
        echo -n "Rollback ${file}..."

        if [ "$SG_DRY_RUN" == "true" ]; then
            echo "done."
            echo ">> Contents of file $SG_MIGRATED_DIR/$SG_ENVIRONMENT/${file}: "
            cat "$SG_MIGRATED_DIR/$SG_ENVIRONMENT/$file" && echo ""

            continue
        fi

        sg_log "Running command: mysql --defaults-file=$SG_MYSQL_CONFIG_FILE $SG_DB_NAME < $SG_MIGRATED_DIR/$SG_ENVIRONMENT/$file 2>&1 >/dev/null"
        SG_ROLLBACK_ERROR="$( mysql --defaults-file=$SG_MYSQL_CONFIG_FILE $SG_DB_NAME < $SG_MIGRATED_DIR/$SG_ENVIRONMENT/$file 2>&1 >/dev/null )"

        if [ $? -eq 0 ]; then
            echo "done."

            # Remove the file, so it can be rerun again in the future
            rm "$SG_MIGRATED_DIR/$SG_ENVIRONMENT/$file"
        else
            echo "failed."
            sg_err "Failed rolling back $SG_MIGRATED_DIR/$SG_ENVIRONMENT/$file with message: $SG_ROLLBACK_ERROR"
            exit 3
        fi
    done

    [ $SG_COUNTER -eq 0 ] && echo "Nothing to rollback."
}

# Parse the arguments
while getopts c:a:be:hm:rv SG_OPT;
do
    case $SG_OPT in
        a)
            SG_DB_NAME="$OPTARG"
            SG_DO_MIGRATION="true"
        ;;

        b)
            SG_ROLLBACK_MODE="true"
            SG_DO_MIGRATION="true"
        ;;

        e)
            SG_ENVIRONMENT="$OPTARG"
            SG_DO_MIGRATION="true"
        ;;

        h)
            sg_help
            exit 0
        ;;

        m)
            sg_create_migration_file "$OPTARG"
        ;;

        r)
            sg_log "Running in DRY RUN mode"
            SG_DRY_RUN="true"
            SG_DO_MIGRATION="true"
        ;;

        v)
            echo "shgrate version ${SG_VERSION}."
            exit 0
        ;;

        \?)
            sg_help
            exit 1
        ;;
    esac
done

# No argument given
[ $# -eq 0 ] && SG_DO_MIGRATION="true"

if [ "$SG_DO_MIGRATION" == "true" ]; then
    if [ "$SG_ROLLBACK_MODE" == "false" ]; then
        sg_migrate
    else
        sg_rollback
    fi
fi

exit 0
