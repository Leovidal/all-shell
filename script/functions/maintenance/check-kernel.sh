#!/bin/bash
##################################################
# Name: check-kernel.sh
# Description: Checks running kernel vs newest installed, emails if diffrent.
##################################################
# Set Variables
#
EMAIL="changeme@email.com"
KERNEL=$(rpm -q kernel |tail -n1|sed -e 's/kernel-//')
HOSTNAME=$(/bin/hostname)
#
##################################################
# Main Script
#
echo "$KERNEL"

if uname -a | grep -qv "$KERNEL"; then
	echo "Running Kernel is" `uname -r` "but latest installed rpm is ${KERNEL}" | mailx -s "UPDATE: $HOSTNAME Reboot Required" $EMAIL
fi;
# EOF
