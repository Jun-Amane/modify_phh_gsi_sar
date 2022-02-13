# !/bin/sh

#  author: Yahoo Mike @ xda-developers
#          Jun ASAKA @ xda-developers
#    date: 13 February 2022
# version: 3.1

usage () {
	echo " "
	echo "usage:  modify_phh_gsi.sh"
	echo " "
	echo "        modifies the /system/bin/rw-system.sh file on a phh-based  "
	echo "        GSI system image to comment out the attempt to remount     "
	echo "        /system as rw and the attempt to run resize2fs at boottime."
	echo "        It also corrects the mount binding for the library         "
	echo "        stagefright-foundation.so in Android 11 GSIs.              "
	echo " "
	echo "On the Lenovo TB-X605F/L and TB-X705F/L, the tablet does not allow "
	echo "the system partition to be remounted as read-write during boot.    "
	echo "When the GSI ROM does this, the tablet aborts the init process and "
	echo "freezes on the Lenovo logo before the boot animation."
	echo " "
	echo "This script does three things:"
	echo " 1. runs the resize2fs command that rw-system.sh is trying to run."
	echo " 2. modifies the rw-system.sh file on the GSI ROM to stop it from "
	echo "    remounting /system rw during boot."
	echo " 3. corrects binding of libstagefright_foundation.so   "
	echo " "
	echo "This script is only required if you are loading a phhusson-based"
	echo "GSI ROM over the Lenovo stock Pie ROM.  It is not required when"
	echo "loading over the Lenovo stock Oreo ROM."
	echo " "
	echo "Run this script from recovery (TWRP).  It is assumed that you have"
	echo "flashed a phhusson-based GSI ROM to the /system partition already."
	echo " "
	echo "This script is only supported for Lenovo TB-X605F/L and TB-X705F/L."
	echo " "
}


# all the heavy lifting (modifies rw-system.sh)
modify_file () {

    # create temp file to store the modified rw-system.sh
    temp_file=$(mktemp --tmpdir="/tmp")

    # first and last lines to comment out in rw-system.sh
    first_line="if mount -o remount,rw /system; then"
    last_line="mount -o remount,ro / || true"

    # traverse lines in rw-system.sh and comment out lines between first_line and last_line (inclusive)
    comment_out=false
    IFS=''
    while read -r line; do
	if [[ $line == *${first_line}* ]]; then
		# this is the first line to comment out
		comment_out=true
	fi

	if [[ $comment_out == true ]]; then

		if [[ ${line:0:1} == "#" ]]; then
			# this has already been commented out - so just echo the line
			echo "$line"
		else
			# comment out this line
			echo "# $line"
		fi

	    	if [[ $line == *${last_line}* ]]; then
			# this is the last to comment out, so stop commenting out after this
			comment_out=false
		fi

	else
		# just echo the line - don't comment it out
		echo "$line"
	fi

    done  < "/system/bin/rw-system.sh"  > $temp_file

    # double-check we have copied out all the lines 
    if [[ $(wc -l < /system/bin/rw-system.sh) -ne $(wc -l < $temp_file) ]]; then
    	echo "ERROR: unexpected.  Not all lines in rw-system.sh would be copied.  Aborting..."
    	exit 1
    fi

    # copy the temp file to rw-system.sh with correct mode & context
    cp -np /system/bin/rw-system.sh /system/bin/rw-system.bak
    cp -f $temp_file /system/bin/rw-system.sh
    chmod 755 /system/bin/rw-system.sh
    chcon u:object_r:phhsu_exec:s0 /system/bin/rw-system.sh

    # clean up
    rm $temp_file

}

##########################################################################################
# NOTE: there are lots of checks - to try to make this as dummy-proof as possible

# 0. command line parameter check
if [ "$#" -ne 0 ]; then
    usage
    exit 1
fi

# 1. check we are root user
if [[ $(whoami) -ne "root" ]]; then
    echo "ERROR: not root user.  You must be root to run this script."
    exit 1
fi

# 2. check we are in recovery
if [[ $(getprop ro.twrp.boot) != *"1"* ]]; then
    echo "ERROR: not in recovery mode.  You must be in recovery (twrp) to run this script."
    exit 1
fi

# 3. check if device has been re-configured as system-as-root (SAR)
_SAR=0
if [[ $(getprop ro.twrp.sar) == "true" ]]; then
    # device modified to be SAR (using MakeMeSAR or similar)
    # see: https://forum.xda-developers.com/t/android-s-gsi-system-as-root-on-on-smart-tab-m10-tb-x605f.4400689/
    _SAR=1
    echo "System As Root detected"
fi

# 4. check integrity and resize fs on /system
umount /system 2>/dev/null
umount /system_root 2>/dev/null

# some devices require an integrity check before resizing...
echo "Running e2fsck..."
e2fsck -fp /dev/block/bootdevice/by-name/system
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "ERROR: failed to check integrity of system filesystem with rc=$rc"
    exit 1
fi

echo "Running resize2fs..."
resize2fs /dev/block/bootdevice/by-name/system
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "ERROR: failed to resize system filesystem to partition size with rc=$rc"
    exit 1
fi

# 5. mount /system (and /system_root for SAR) rw
if [ $_SAR -eq 0 ]; then
    # stock non-SAR device
    mount -o rw /system
    rc=$?
else
    mount -o rw /dev/block/bootdevice/by-name/system /system_root/
    mount -o bind /system_root/system /system
    rc=$?
fi
if [[ $rc -ne 0 ]]; then
    echo "ERROR: failed to mount /system read-write with rc=$rc"
    exit 1
fi

# 6. check that /system/bin/rw-system.sh exists
if [ ! -f "/system/bin/rw-system.sh" ]; then
    echo "ERROR: /system/bin/rw-system.sh does not exist.  Is this a phhusson-based GSI ROM?"
    exit 1
fi

echo "System mounted and all initial checks passed..."

# 7. read rw-system.sh and comment out the offending lines
echo "Modifying rw-system.sh..."
modify_file
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "ERROR: failed to modify rw-system.sh with rc=$rc"
    exit 1
fi

# 8. for Android 11+ GSIs, correct the mount binding of libstagefright_foundation.so
#    For more info see: https://github.com/phhusson/treble_experimentations/issues/1917
#    NOTE: this will have no effect on Android 10 GSIs.
echo "Correcting mount bindings for Android 11+ GSIs..."
sed -i 's|/system/system_ext/apex/|/apex/|' /system/bin/rw-system.sh
	
chmod 755 /system/bin/rw-system.sh
chcon u:object_r:phhsu_exec:s0 /system/bin/rw-system.sh

# 9. unmount /system (and /system_root for SAR)
umount /system 2>/dev/null
umount /system_root 2>/dev/null

echo " "
echo "...finished."
