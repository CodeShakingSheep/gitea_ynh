# Start (or other actions) a service,  print a log in case of failure and optionnaly wait until the service is completely started
#
# usage: ynh_systemd_action [-n service_name] [-a action] [ [-l "line to match"] [-p log_path] [-t timeout] [-e length] ]
# | arg: -n, --service_name= - Name of the service to reload. Default : $app
# | arg: -a, --action=       - Action to perform with systemctl. Default: start
# | arg: -l, --line_match=   - Line to match - The line to find in the log to attest the service have finished to boot.
#                              If not defined it don't wait until the service is completely started.
# | arg: -p, --log_path=     - Log file - Path to the log file. Default : /var/log/$app/$app.log
# | arg: -t, --timeout=      - Timeout - The maximum time to wait before ending the watching. Default : 300 seconds.
# | arg: -e, --length=       - Length of the error log : Default : 20
ynh_systemd_action() {
    # Declare an array to define the options of this helper.
    declare -Ar args_array=( [n]=service_name= [a]=action= [l]=line_match= [p]=log_path= [t]=timeout= [e]=length= )
    local service_name
    local action
    local line_match
    local length
    local log_path
    local timeout

    # Manage arguments with getopts
    ynh_handle_getopts_args "$@"

    local service_name="${service_name:-$app}"
    local action=${action:-start}
    local log_path="${log_path:-/var/log/$service_name/$service_name.log}"
    local length=${length:-20}
    local timeout=${timeout:-300}

    # Start to read the log
    if [[ -n "${line_match:-}" ]]
    then
        local templog="$(mktemp)"
        # Following the starting of the app in its log
        if [ "$log_path" == "systemd" ] ; then
            # Read the systemd journal
            journalctl --unit=$service_name --follow --since=-0 --quiet > "$templog" &
        else
            # Read the specified log file
            tail -F -n0 "$log_path" > "$templog" &
        fi
        # Get the PID of the tail command
        local pid_tail=$!
    fi

    echo "${action^} the service $service_name" >&2
    systemctl $action $service_name \
        || ( journalctl --lines=$length -u $service_name >&2 \
        ; test -e "$log_path" && echo "--" && tail --lines=$length "$log_path" >&2 \
        ; false )

    # Start the timeout and try to find line_match
    if [[ -n "${line_match:-}" ]]
    then
        local i=0
        for i in $(seq 1 $timeout)
        do
            # Read the log until the sentence is found, that means the app finished to start. Or run until the timeout
            if grep --quiet "$line_match" "$templog"
            then
                echo "The service $service_name has correctly started." >&2
                break
            fi
            echo -n "." >&2
            sleep 1
        done
        if [ $i -eq $timeout ]
        then
            echo "The service $service_name didn't fully started before the timeout." >&2
            echo "Please find here an extract of the end of the log of the service $service_name:"
            journalctl --lines=$length -u $service_name >&2
            test -e "$log_path" && echo "--" && tail --lines=$length "$log_path" >&2
        fi

        echo ""
        ynh_clean_check_starting
    fi
}

# Execute a command as another user
# usage: exec_as USER COMMAND [ARG ...]
exec_as() {
  local USER=$1
  shift 1

  if [[ $USER = $(whoami) ]]; then
    eval "$@"
  else
    sudo -u "$USER" "$@"
  fi
}

# Need also the helper https://github.com/YunoHost-Apps/Experimental_helpers/blob/master/ynh_handle_getopts_args/ynh_handle_getopts_args

# Make the main steps to migrate an app to its fork.
#
# This helper has to be used for an app which needs to migrate to a new name or a new fork
# (like owncloud to nextcloud or zerobin to privatebin).
#
# This helper will move the files of an app to its new name
# or recreate the things it can't move.
#
# To specify which files it has to move, you have to create a "migration file", stored in ../conf
# This file is a simple list of each file it has to move,
# except that file names must reference the $app variable instead of the real name of the app,
# and every instance-specific variables (like $domain).
# $app is especially important because it's this variable which will be used to identify the old place and the new one for each file.
#
# If a database exists for this app, it will be dumped and then imported in a newly created database, with a new name and new user.
# Don't forget you have to then apply these changes to application-specific settings (depends on the packaged application)
#
# Same things for an existing user, a new one will be created.
# But the old one can't be removed unless it's not used. See below.
#
# If you have some dependencies for your app, it's possible to change the fake debian package which manages them.
# You have to fill the $pkg_dependencies variable, and then a new fake package will be created and installed,
# and the old one will be removed.
# If you don't have a $pkg_dependencies variable, the helper can't know what the app dependencies are.
#
# The app settings.yml will be modified as follows:
# - finalpath will be changed according to the new name (but only if the existing $final_path contains the old app name)
# - The checksums of php-fpm and nginx config files will be updated too.
# - If there is a $db_name value, it will be changed.
# - And, of course, the ID will be changed to the new name too.
#
# Finally, the $app variable will take the value of the new name.
# The helper will set the $migration_process variable to 1 if a migration has been successfully handled.
#
# You have to handle by yourself all the migrations not done by this helper, like configuration or special values in settings.yml
# Also, at the end of the upgrade script, you have to add a post_migration script to handle all the things the helper can't do during YunoHost upgrade (mostly for permission reasons),
# especially remove the old user, move some hooks and remove the old configuration directory
# To launch this script, you have to move it elsewhere and start it after the upgrade script.
# `cp ../conf/$script_post_migration /tmp`
# `(cd /tmp; echo "/tmp/$script_post_migration" | at now + 2 minutes)`
#
# usage: ynh_handle_app_migration migration_id migration_list
# | arg: -i, --migration_id= - ID from which to migrate
# | arg: -l, --migration_list= - File specifying every file to move (one file per line)
ynh_handle_app_migration ()  {
  # Need for end of install
  ynh_package_install at

  #=================================================
  # LOAD SETTINGS
  #=================================================

  old_app=$YNH_APP_INSTANCE_NAME
  local old_app_id=$YNH_APP_ID
  local old_app_number=$YNH_APP_INSTANCE_NUMBER

  # Declare an array to define the options of this helper.
  declare -Ar args_array=( [i]=migration_id= [l]=migration_list= )
  # Get the id from which to migrate
  local migration_id
  # And the file with the paths to move
  local migration_list
  # Manage arguments with getopts
  ynh_handle_getopts_args "$@"

  # Get the new app id in the manifest
  local new_app_id=$(grep \"id\": ../manifest.json | cut -d\" -f4)
  if [ $old_app_number -eq 1 ]; then
    local new_app=$new_app_id
  else
    local new_app=${new_app_id}__${old_app_number}
  fi

  #=================================================
  # CHECK IF IT HAS TO MIGRATE 
  #=================================================

  migration_process=0

  if [ "$old_app_id" == "$new_app_id" ]
  then
    # If the 2 id are the same
    # No migration to do.
    echo 0
    return 0
  else
    if [ "$old_app_id" != "$migration_id" ]
    then
        # If the new app is not the authorized id, fail.
        ynh_die --message "Incompatible application for migration from $old_app_id to $new_app_id"
    fi

    echo "Migrate from $old_app_id to $new_app_id" >&2

    #=================================================
    # CHECK IF THE MIGRATION CAN BE DONE
    #=================================================

    # TODO Handle multi instance apps...
    # Check that there is not already an app installed for this id.
    (yunohost app list --installed -f "$new_app" | grep -q id) \
    && ynh_die "$new_app is already installed"

    #=================================================
    # CHECK THE LIST OF FILES TO MOVE
    #=================================================

    local temp_migration_list="$(tempfile)"

    # Build the list by removing blank lines and comment lines
    sed '/^#.*\|^$/d' "../conf/$migration_list" > "$temp_migration_list"

    # Check if there is no file in the destination
    local file_to_move=""
    while read file_to_move
    do
        # Replace all occurences of $app by $new_app in each file to move.
        local move_to_destination="${file_to_move//\$app/$new_app}"
        test -e "$move_to_destination" && ynh_die "A file named $move_to_destination already exists."
    done < "$temp_migration_list"

    #=================================================
    # COPY YUNOHOST SETTINGS FOR THIS APP
    #=================================================

    local settings_dir="/etc/yunohost/apps"
    cp -a "$settings_dir/$old_app" "$settings_dir/$new_app"
    cp -a ../{scripts,conf} "$settings_dir/$new_app"

    # Replace the old id by the new one
    ynh_replace_string "\(^id: .*\)$old_app" "\1$new_app" "$settings_dir/$new_app/settings.yml"
    # INFO: There a special behavior with yunohost app setting:
    # if the id given in argument does not match with the id
    # stored in the config file, the config file will be purged.
    # That's why we use sed instead of app setting here.
    # https://github.com/YunoHost/yunohost/blob/c6b5284be8da39cf2da4e1036a730eb5e0515096/src/yunohost/app.py#L1316-L1321

    # Change the label if it's simply the name of the app
    old_label=$(ynh_app_setting_get $new_app label)
    if [ "${old_label,,}" == "$old_app_id" ]
    then
        # Build the new label from the id of the app. With the first character as upper case
        new_label=$(echo $new_app_id | cut -c1 | tr [:lower:] [:upper:])$(echo $new_app_id | cut -c2-)
        ynh_app_setting_set $new_app label $new_label
    fi
    
    yunohost tools shell -c "from yunohost.permission import permission_delete; permission_delete('$old_app.main', force=True, sync_perm=False)"
    yunohost tools shell -c "from yunohost.permission import permission_create; permission_create('$new_app.main', url='/' , sync_perm=True)"

    #=================================================
    # MOVE FILES TO THE NEW DESTINATION
    #=================================================

    while read file_to_move
    do
        # Replace all occurence of $app by $new_app in each file to move.
        move_to_destination="$(eval echo "${file_to_move//\$app/$new_app}")"
        local real_file_to_move="$(eval echo "${file_to_move//\$app/$old_app}")"
        echo "Move file $real_file_to_move to $move_to_destination" >&2
        mv "$real_file_to_move" "$move_to_destination"
    done < "$temp_migration_list"

    #=================================================
    # UPDATE SETTINGS KNOWN ENTRIES
    #=================================================

    # Replace nginx checksum
    ynh_replace_string "\(^checksum__etc_nginx.*\)_$old_app" "\1_$new_app/" "$settings_dir/$new_app/settings.yml"

    # Replace php5-fpm checksums
    ynh_replace_string "\(^checksum__etc_php5.*[-_]\)$old_app" "\1$new_app/" "$settings_dir/$new_app/settings.yml"

    # Replace final_path
    ynh_replace_string "\(^final_path: .*\)$old_app" "\1$new_app" "$settings_dir/$new_app/settings.yml"

    #=================================================
    # MOVE THE DATABASE
    #=================================================

    db_pwd=$(ynh_app_setting_get $old_app mysqlpwd)
    db_name=$dbname

    # Check if a database exists before trying to move it
    local mysql_root_password=$(cat $MYSQL_ROOT_PWD_FILE)
    if [ -n "$db_name" ] && mysqlshow -u root -p$mysql_root_password | grep -q "^| $db_name"
    then
        new_db_name=$(ynh_sanitize_dbid $new_app)
        echo "Rename the database $db_name to $new_db_name" >&2

        local sql_dump="/tmp/${db_name}-$(date '+%s').sql"

        # Dump the old database
        ynh_mysql_dump_db "$db_name" > "$sql_dump"

        # Create a new database
        ynh_mysql_setup_db $new_db_name $new_db_name $db_pwd
        # Then restore the old one into the new one
        ynh_mysql_connect_as $new_db_name $db_pwd $new_db_name < "$sql_dump"

        # Remove the old database
        ynh_mysql_remove_db $db_name $db_name
        # And the dump
        ynh_secure_remove --file="$sql_dump"

        # Update the value of $db_name
        db_name=$new_db_name
        ynh_app_setting_set $new_app db_name $db_name
    fi

    #=================================================
    # CHANGE THE FAKE DEPENDENCIES PACKAGE
    #=================================================

    # Check if a variable $pkg_dependencies exists
    # If this variable doesn't exist, this part shall be managed in the upgrade script.
    if [ -n "${pkg_dependencies:-}" ]
    then
      # Define the name of the package
      local old_package_name="${old_app//_/-}-ynh-deps"
      local new_package_name="${new_app//_/-}-ynh-deps"

      if ynh_package_is_installed "$old_package_name"
      then
        # Install a new fake package
        app=$new_app
        ynh_install_app_dependencies $pkg_dependencies
        # Then remove the old one
        app=$old_app
        ynh_remove_app_dependencies
      fi
    fi

    #=================================================
    # UPDATE THE ID OF THE APP
    #=================================================

    app=$new_app

    # Set migration_process to 1 to inform that an upgrade has been made
    migration_process=1
  fi
}

# Verify the checksum and backup the file if it's different
# This helper is primarily meant to allow to easily backup personalised/manually
# modified config files.
#
# $app should be defined when calling this helper
#
# usage: ynh_backup_if_checksum_is_different --file=file
# | arg: -f, --file - The file on which the checksum test will be perfomed.
# | ret: the name of a backup file, or nothing
#
# Requires YunoHost version 2.6.4 or higher.
ynh_backup_if_checksum_is_different () {
    # Declare an array to define the options of this helper.
    local legacy_args=f
    declare -Ar args_array=( [f]=file= )
    local file
    # Manage arguments with getopts
    ynh_handle_getopts_args "$@"

    local checksum_setting_name=checksum_${file//[\/ ]/_}    # Replace all '/' and ' ' by '_'
    local checksum_value=$(ynh_app_setting_get --app=$app --key=$checksum_setting_name)
    # backup_file_checksum isn't declare as local, so it can be reuse by ynh_store_file_checksum
    backup_file_checksum=""
    if [ -n "$checksum_value" ]
    then    # Proceed only if a value was stored into the app settings
        if [ -e $file ] && ! echo "$checksum_value $file" | sudo md5sum -c --status
        then    # If the checksum is now different
            backup_file_checksum="/home/yunohost.conf/backup/$file.backup.$(date '+%Y%m%d.%H%M%S')"
            sudo mkdir -p "$(dirname "$backup_file_checksum")"
            sudo cp -a "$file" "$backup_file_checksum"    # Backup the current file
            ynh_print_warn "File $file has been manually modified since the installation or last upgrade. So it has been duplicated in $backup_file_checksum"
            echo "$backup_file_checksum"    # Return the name of the backup file
        fi
    fi
}
