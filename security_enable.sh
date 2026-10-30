#!/usr/bin/env bash
# https://privacy.sexy - v0.13.7 - Sun, 08 Dec 2024 17:04:46 GMT
# My warning to myself, because the file name lies: this is the revert
# export for a small set of tweaks I picked in privacy.sexy, not a
# hardening script and not the undo for privacy-script.sh, which
# covers different tweaks entirely. Most sections below turn things
# back on: automatic updates, the downloaded file warning, beta
# installs. I keep it so the changes in that tweak set can be reversed
# on purpose, and I never run it expecting a machine to end up safer.
if [ "$EUID" -ne 0 ]; then
    script_path=$([[ "$0" = /* ]] && echo "$0" || echo "$PWD/${0#./}")
    sudo "$script_path" || (
        echo 'Administrator privileges are required.'
        exit 1
    )
    exit 0
fi


# ----------------------------------------------------------
# -Clear logs of all downloaded files from File Quarantine--
# ----------------------------------------------------------
echo '--- Clear logs of all downloaded files from File Quarantine'
db_file=~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2
db_query='delete from LSQuarantineEvent'
# The immutable flags are the reason this section is shaped the way it
# is: sqlite3 cannot write to a file flagged schg or uchg, so the
# flags come off first, and whichever ones were set go back on after
# the delete. The two has_ variables are the memory of what to
# restore. If the delete itself fails, the flags still go back on and
# the echo lines still claim the query ran, so this section can
# report success over a database that never changed.
if [ -f "$db_file" ]; then
    echo "Database exists at \"$db_file\""
    if ls -lO "$db_file" | grep --silent 'schg'; then
        sudo chflags noschg "$db_file"
        echo "Found and removed system immutable flag"
        has_system_immutable_flag=true
    fi
    if ls -lO "$db_file" | grep --silent 'uchg'; then
        sudo chflags nouchg "$db_file"
        echo "Found and removed user immutable flag"
        has_user_immutable_flag=true
    fi
    sqlite3 "$db_file" "$db_query"
    echo "Executed the query \"$db_query\""
    if [ "$has_system_immutable_flag" = true ] ; then
        sudo chflags schg "$db_file"
        echo "Added system immutable flag back"
    fi
    if [ "$has_user_immutable_flag" = true ] ; then
        sudo chflags uchg "$db_file"
        echo "Added user immutable flag back"
    fi
else
    echo "No action needed, database does not exist at \"$db_file\""
fi
# ----------------------------------------------------------


# ----------------------------------------------------------
# --Clear File Quarantine attribute from downloaded files---
# ----------------------------------------------------------
echo '--- Clear File Quarantine attribute from downloaded files'
# Known weak spot in this generated block: the file name reaches the
# inner script as "{}" inside double quotes in the sh -c text, so a
# downloaded file whose name contains a double quote breaks the inner
# command for that file. It fails per file and the find keeps going,
# so the section finishes looking normal with some files untouched.
find ~/Downloads        \
        -type f         \
        -exec           \
            sh -c       \
                '
                    attr="com.apple.quarantine"
                    file="{}"
                    if [[ $(xattr "$file") = *$attr* ]]; then
                        if xattr -d "$attr" "$file" 2>/dev/null; then
                            echo "🧹 Cleaned attribute from \"$file\""
                        else
                            >&2 echo "❌ Failed to clean attribute from \"$file\""
                        fi
                    else
                        echo "No attribute in \"$file\""
                    fi
                '       \
            {} \;
# ----------------------------------------------------------


# ----------------------------------------------------------
# --Disable downloaded file logging in quarantine (revert)--
# ----------------------------------------------------------
echo '--- Disable downloaded file logging in quarantine (revert)'
file_to_lock=~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2
# This section reaches back into the same database file the first
# section just restored flags on, and takes schg off again for good.
# The order is the whole meaning here: run these sections in the
# other order and the first section would put the lock back. The end
# state of the file is schg off, uchg left as it was.
if [ -f "$file_to_lock" ]; then
    sudo chflags noschg "$file_to_lock"
    echo "Successfully reverted immutability from \"$file_to_lock\""
else
    >&2 echo "Cannot revert immutability, file does not exist at\"$file_to_lock\""
fi
# ----------------------------------------------------------


# Disable extended quarantine attribute for downloaded files (disables warning) (revert)
echo '--- Disable extended quarantine attribute for downloaded files (disables warning) (revert)'
sudo defaults delete com.apple.LaunchServices 'LSQuarantine'
# ----------------------------------------------------------


# ----------------------------------------------------------
# ---Disable Gatekeeper's automatic reactivation (revert)---
# ----------------------------------------------------------
echo '--- Disable Gatekeeper'\''s automatic reactivation (revert)'
sudo defaults write /Library/Preferences/com.apple.security GKAutoRearm -bool false
# ----------------------------------------------------------


# ----------------------------------------------------------
# ---------------Disable Gatekeeper (revert)----------------
# ----------------------------------------------------------
echo '--- Disable Gatekeeper (revert)'
os_major_ver=$(sw_vers -productVersion | awk -F "." '{print $1}')
os_minor_ver=$(sw_vers -productVersion | awk -F "." '{print $2}')
# A flaw I know is in this generated gate, stated plainly: the first
# clause, major version at or below 10, already covers every case the
# second clause names, so the second clause can never change the
# result. On macOS 10.x this section prints that Gatekeeper is not
# available and skips, even though Gatekeeper exists on every 10.x
# release this script would meet. In practice the enable below only
# runs on macOS 11 and later.
if [[ $os_major_ver -le 10 \
        || ( $os_major_ver -eq 10 && $os_minor_ver -lt 7 ) \
    ]]; then
    >&2 echo "Gatekeeper is not available in this OS version"
else
    # The quotes on the two status tests below are a fix of mine. The
    # generated version compared the bare variable, and when spctl
    # printed nothing the tests errored with "unary operator
    # expected" and the run exited 1 after doing its work. Quoted, an
    # empty status lands in the Unknown branch, which is where it
    # belongs. The same pattern in the quarantine section above was
    # already quoted in the generated text.
    gatekeeper_status="$(spctl --status | awk '/assessments/ {print $2}')"
    if [ "$gatekeeper_status" = "disabled" ]; then
        sudo spctl --master-enable
        sudo defaults write '/var/db/SystemPolicy-prefs' 'enabled' -string 'yes'
        echo "Enabled Gatekeeper"
    elif [ "$gatekeeper_status" = "enabled" ]; then
        echo "No action needed, Gatekeeper is already enabled"
    else
        >&2 echo "Unknown Gatekeeper status: $gatekeeper_status"
    fi
fi
# ----------------------------------------------------------


# ----------------------------------------------------------
# ------Disable automatic checks for updates (revert)-------
# ----------------------------------------------------------
echo '--- Disable automatic checks for updates (revert)'
# For OS X Yosemite and newer (>= 10.10)
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate 'AutomaticCheckEnabled' -bool true
# ----------------------------------------------------------


# ----------------------------------------------------------
# -----Disable automatic downloads for updates (revert)-----
# ----------------------------------------------------------
echo '--- Disable automatic downloads for updates (revert)'
# For OS X Yosemite and newer (>= 10.10)
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate 'AutomaticDownload' -bool true
# ----------------------------------------------------------


# ----------------------------------------------------------
# -Disable automatic installation of macOS updates (revert)-
# ----------------------------------------------------------
echo '--- Disable automatic installation of macOS updates (revert)'
# For OS X Yosemite through macOS High Sierra (>= 10.10 && < 10.14)
sudo defaults write /Library/Preferences/com.apple.commerce 'AutoUpdateRestartRequired' -bool true
# For Mojave and newer (>= 10.14)
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate 'AutomaticallyInstallMacOSUpdates' -bool true
# ----------------------------------------------------------


# ----------------------------------------------------------
# Disable automatic app updates from the App Store (revert)-
# ----------------------------------------------------------
echo '--- Disable automatic app updates from the App Store (revert)'
# For OS X Yosemite and newer
sudo defaults write /Library/Preferences/com.apple.commerce 'AutoUpdate' -bool true
# For Mojave and newer (>= 10.14)
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate 'AutomaticallyInstallAppUpdates' -bool true
# ----------------------------------------------------------


# ----------------------------------------------------------
# -----Disable macOS beta release installation (revert)-----
# ----------------------------------------------------------
echo '--- Disable macOS beta release installation (revert)'
# For OS X Yosemite and newer (>= 10.10)
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate 'AllowPreReleaseInstallation' -bool true
# ----------------------------------------------------------


# Disable automatic installation for configuration data (e.g. XProtect, Gatekeeper, MRT) (revert)
echo '--- Disable automatic installation for configuration data (e.g. XProtect, Gatekeeper, MRT) (revert)'
# For OS X Yosemite and newer (>= 10.10)
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate 'ConfigDataInstall' -bool true
# ----------------------------------------------------------


# Disable automatic installation for system data files and security updates (revert)
echo '--- Disable automatic installation for system data files and security updates (revert)'
# For OS X Yosemite and newer (>= 10.10)
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate 'CriticalUpdateInstall' -bool true
# Trigger background check with normal scan (critical updates only)
sudo softwareupdate --background-critical
# ----------------------------------------------------------


# Disable library validation entitlement (library signature validation) (revert)
echo '--- Disable library validation entitlement (library signature validation) (revert)'
sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist 'DisableLibraryValidation' -bool false
# ----------------------------------------------------------


echo 'Your privacy and security is now hardened 🎉💪'
echo 'Press any key to exit.'
# My || true, same as in privacy-script.sh: a closed stdin used to
# make a completed run exit 1. The closing message above is generated
# text and is wrong for this file, since most of what it just did was
# revert settings. I leave the message because it is part of the
# generated export, and the README and the header note in this file
# carry the true description.
read -n 1 -s || true
