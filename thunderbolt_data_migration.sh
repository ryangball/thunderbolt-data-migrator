#!/bin/bash

# Written by Ryan Ball
# Originally obtained from: https://github.com/ryangball/thunderbolt-data-migration

# This variable can be used if you are testing the script
# Set to true while testing, the rsync will be bypassed and nothing permanent will done to this Mac
# Set to false when used in production
testing="true"  # (true|false)

# The full path of the log file
log="/Library/Logs/tunderbolt_data_migration.log"

# The main icon displayed in jamfHelper dialogs
icon="/Applications/Utilities/Migration Assistant.app/Contents/Resources/MigrateAsst.icns"

# The instructions that are shown in the first dialog to the user
instructions="You can now migrate your data from your old Mac.

1. Turn your old Mac off.

2. Connect your old Mac and new Mac together using the supplied Thunderbolt cable.

3. Power on your old Mac by normally pressing the power button WHILE holding the \"T\" button down for several seconds.

We will attempt to automatically detect your old Mac now..."

###### Variables below this point are not intended to be modified ######
scriptName=$(basename "$0")
jamfHelper=/Library/Application\ Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper

function writelog () {
    DATE=$(date +%Y-%m-%d\ %H:%M:%S)
    /bin/echo "${1}"
    /bin/echo "$DATE" " $1" >> "$log"
}

function finish () {
    writelog "======== Finished $scriptName ========"
    ps -p "$jamfHelperPID" > /dev/null && kill "$jamfHelperPID"; wait "$jamfHelperPID" 2>/dev/null
    rm /tmp/output.txt
    exit "$1"
}

function wait_for_gui () {
    # Wait for the Dock to determine the current user
    DOCK_STATUS=$(pgrep -x Dock)
    writelog "Waiting for Desktop..."

    while [[ "$DOCK_STATUS" == "" ]]; do
        writelog "Desktop is not loaded; waiting..."
        sleep 5
        DOCK_STATUS=$(pgrep -x Dock)
    done

    loggedInUser=$(/usr/bin/python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser; import sys; username = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]; username = [username,""][username in [u"loginwindow", None, u""]]; sys.stdout.write(username + "\n");')
    writelog "$loggedInUser is logged in and at the desktop; continuing."
}

function wait_for_jamfHelper () {
    # Make sure jamfHelper has been installed
    writelog "Waiting for jamfHelper to be installed..."
    while [[ ! -e "$jamfHelper" ]]; do
        sleep 2
    done
    writelog "jamfHelper detected; continuing."
}

function perform_rsync () {
    writelog "Beginning rsync transfer..."
    "$jamfHelper" -windowType fs -title "" -icon "$icon" -heading "Please wait as we transfer your old data to your new Mac..." \
        -description "This might take a few minutes. Once the transfer is complete this screen will close." &>/dev/null &
    jamfHelperPID=$(/bin/echo $!)

    if [[ "$testing" != "true" ]]; then
    # Perform the rsync
    /usr/bin/rsync -vrpog --progress --update --ignore-errors --force \
    --exclude='Library' --exclude='Microsoft User Data' --exclude='.DS_Store' --exclude='.Trash' \
    --log-file="$log" "$oldUserHome/" "/Users/$loggedInUser/"

    # Ensure permissions are correct
    /usr/sbin/chown -R "$loggedInUser" "/Users/$loggedInUser" 2>/dev/null
    else
        writelog "Sleeping for 10 to simulate rsync..."
        sleep 10
    fi

    ps -p "$jamfHelperPID" > /dev/null && kill "$jamfHelperPID"; wait "$jamfHelperPID" 2>/dev/null
    writelog "Finished rsync transfer."
    /usr/sbin/diskutil unmount "/Volumes/$tBoltVolume" &>/dev/null
    finish 0
}

function calculate_space_requirements () {
    # Determine free space on this Mac
    freeOnNewMac=$(df -k / | tail -n +2 | awk '{print $4}')
    writelog "Free space on this Mac: $freeOnNewMac KB ($((freeOnNewMac/1024)) MB)"

    # Determine how much space the old home folder takes up
    spaceRequired=$(du -sck "$oldUserHome" | grep total | awk '{print $1}')
    writelog "Storage requirements for \"$oldUserHome\": $spaceRequired KB ($((spaceRequired/1024)) MB)"

    if [[ "$freeOnNewMac" -gt "$spaceRequired" ]]; then
        writelog "There is more than $spaceRequired KB available on this Mac; continuing."
        perform_rsync
    else
        writelog "Not enough free space on this Mac; exiting."
        "$jamfHelper" -windowType utility -title "User Data Transfer" -icon "$icon" -description "Your new Mac does not have enough free space to transfer your old data over. If you want to try again, please contact the Help Desk." -button1 "OK" -calcelButton "1" -defaultButton "1" &>/dev/null &
        finish 1
    fi
}

function manually_find_old_user () {
    # Determine all home folders on the old Mac
    oldUsersArray=()
    while IFS='' read -ra line; do oldUsersArray+=("$line"); done < <(/usr/bin/find "/Volumes/$tBoltVolume/Users" -maxdepth 1 -mindepth 1 -type d | awk -F'/' '{print $NF}' | grep -v Shared)

    # Exit if we didn't find any users
    if [[ "${#oldUsersArray[@]}" -eq 0 ]]; then
        echo "No user home folders found in: /Volumes/$tBoltVolume/Users"
        "$jamfHelper" -windowType utility -title "User Data Transfer" -icon "$icon" -description "Could not find any user home folders on the selected Thunderbolt volume. If you have any questions, please contact the Help Desk." -button1 "OK" -calcelButton "1" -defaultButton "1" &>/dev/null &
        finish 1
    fi

    # Show list of home folders so that the user can choose their old username
    # Something like cocoadialog would be preferred here as it has a dropdown, but it's got no Dark Mode :(
    # Heredocs cause some weird allignment issues
dialogOutput=$(/usr/bin/osascript <<EOF
    set ASlist to the paragraphs of "$(printf '%s\n' "${oldUsersArray[@]}")"
    choose from list ASlist with title "User Data Transfer" with prompt "Please choose your user account from your old Mac."
EOF
)

    # If the user chose one, store that as a variable, then see if we have enough space for the old data
    dialogOutput=$(grep -v "false" <<< "$dialogOutput")
    if [[ -n "$dialogOutput" ]]; then
        oldUserName="$dialogOutput"
        oldUserHome="/Volumes/$tBoltVolume/Users/$oldUserName"
        calculate_space_requirements
    else
        writelog "User cancelled; exiting."
        finish 0
    fi
}

function auto_find_old_user () {
    # Automatically loop through the user accounts on the old Mac, if one is found that matches the currently logged in user
    # we assume that is the user account to transfer data from. If a matching user is not found, let them manually chooose.
    while read -r line; do
        if [[ "$line" == "$loggedInUser" ]]; then
            writelog "Found a matching user ($line) on the chosen Thunderbolt volume; continuing."
            oldUserName="$line"
            oldUserHome="/Volumes/$tBoltVolume/Users/$line"
            calculate_space_requirements
        fi
    done < <(/usr/bin/find "/Volumes/$tBoltVolume/Users" -maxdepth 1 -mindepth 1 -type d | awk -F'/' '{print $NF}' | grep -v Shared)
    writelog "User with matching name on old Mac not found, moving on to manual selection."
    manually_find_old_user
}

function choose_tbolt_volume () {
    # Figure out all connected Thunderbolt volumes
    tboltVolumesArray=()
    while IFS='' read -ra line; do
        while IFS='' read -ra line; do tboltVolumesArray+=("$line"); done < <(diskutil info "$line" | grep -B15 "Thunderbolt" | grep "Mount Point" | sed -n -e 's/^.*Volumes\///p')
    done < <(system_profiler SPStorageDataType | grep "BSD Name" | awk '{print $NF}' | sort -u)

    # Exit if we didn't find any connected Thunderbolt volumes
    if [[ "${#tboltVolumesArray[@]}" -eq 0 ]]; then
        writelog "No Thunderbolt volumes connected at this time; exiting."
        "$jamfHelper" -windowType utility -title "User Data Transfer" -icon "$icon" -description "There are no Thunderbolt volumes attached at this time. If you want to try again, please contact the Help Desk." -button1 "OK" -calcelButton "1" -defaultButton "1" &>/dev/null &
        finish 1
    fi

    # Allow the user to choose from a list of connected Thunderbolt volumes
    # Something like cocoadialog would be preferred here as it has a dropdown, but it's got no Dark Mode :(
    # Heredocs cause some weird allignment issues
dialogOutput=$(/usr/bin/osascript <<EOF
    set ASlist to the paragraphs of "$(printf '%s\n' "${tboltVolumesArray[@]}")"
    choose from list ASlist with title "User Data Transfer" with prompt "Please choose the Thunderbolt volume to transfer your data from."
EOF
)

    # If the user chose one, store that as a variable
    dialogOutput=$(grep -v "false" <<< "$dialogOutput")
    if [[ -n "$dialogOutput" ]]; then
        tBoltVolume="$dialogOutput"
        writelog "\"/Volumes/$tBoltVolume\" was selected by the user."
        auto_find_old_user
    else
        writelog "User cancelled; exiting"
        finish 0
    fi
}

function detect_new_tbolt_volumes () {
    # Automaticaly detect a newly added Thunderbolt volume. The timer variable below can be modified to fit your environment
    # Most of this function (in the while loop) will loop every two seconds until the timer is done
    local timer="120"
    writelog "Waiting for Thuderbolt volumes..."
    while [[ "$timer" -gt "0" ]]; do
        # Determine status of jamfHelper
        if [[ "$(cat /tmp/output.txt)" == "0" ]]; then
            writelog "User cancelled; exiting."
            finish 0
        elif [[ "$(cat /tmp/output.txt)" == "2" ]]; then
            writelog "User chose to select a volume themselves."
            while [[ -z "$tBoltVolume" ]]; do
                choose_tbolt_volume
            done
            return
        fi

        # Get the mounted volumes once (before)
        diskListBefore=$(/sbin/mount | grep '/dev/' | grep '/Volumes' | awk '{print $1}')
        diskCountBefore=$(echo -n "$diskListBefore" | grep -c '^')  # This method will produce a 0 if none, where as wc -l will not
        sleep 5

        # Get the mounted volumes 2 seconds later (after)
        diskListAfter=$(/sbin/mount | grep '/dev/' | grep '/Volumes' | awk '{print $1}')
        diskCountAfter=$(echo -n "$diskListAfter" | grep -c '^')  # This method will produce a 0 if none, where as wc -l will not

        # Determine if an additional volume has been mounted since our first check, if so we will check to see if it is Thunderbolt
        # If so, we move on to find the user accounts on the newly connected Thunderbolt volume
        # If not we ignore the newly connected non-Thunderbolt volume
        if [[ "$diskCountBefore" -lt "$diskCountAfter" ]]; then
            additional=$(/usr/bin/comm -13 <(echo "$diskListBefore") <(echo "$diskListAfter"))
            isTBolt=$(/usr/sbin/diskutil info "$additional" | grep -B15 "Thunderbolt" | grep "Mount Point" | sed -n -e 's/^.*Volumes\///p')
            if [[ -n "$isTBolt" ]]; then
                tBoltVolume="$isTBolt"
                writelog "\"/Volumes/$tBoltVolume\" has been detected as a new Thunderbolt volume; continuing."
                ps -p "$jamfHelperPID" > /dev/null && kill "$jamfHelperPID"; wait "$jamfHelperPID" 2>/dev/null
                auto_find_old_user
            fi
        fi
        timer=$((timer-5))
    done
    # At this point the timer has run out, kill the background jamfHelper dialog and let the user know
    ps -p "$jamfHelperPID" > /dev/null && kill "$jamfHelperPID"; wait "$jamfHelperPID" 2>/dev/null
    writelog "Unable to detect a Thunderbolt volume in the amount of time specified; exiting."
    "$jamfHelper" -windowType utility -title "User Data Transfer" -icon "$icon" -description "We were unable to detect your old Mac. If you want to try again, please contact the Help Desk." -button1 "OK" -calcelButton "1" -defaultButton "1" &>/dev/null &
    finish 1
}

writelog " "
writelog "======== Starting $scriptName ========"

# Wait for a GUI
wait_for_gui

# Wait for jamfHelper to be installed
wait_for_jamfHelper

# Display a jamfHelper dialog with instructions as a background task
"$jamfHelper" -windowType utility -title "User Data Transfer" -icon "$icon" -description "$instructions" -button1 "Cancel" -button2 "I'll Pick" -calcelButton "1" -defaultButton "1" > /tmp/output.txt &
jamfHelperPID=$(/bin/echo $!)

# Attempt to detect a new thunderbolt volume, other funtions are chained together
detect_new_tbolt_volumes

finish 0
