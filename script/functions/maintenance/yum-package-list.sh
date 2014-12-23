#!/bin/bash
##################################################
# Name: yum-package-list.sh
# Description: This script generates the package list then you can pipe this list into yum.
##################################################
# Simple One Liner
rpm -qa --qf %{NAME}\ > /blah/packages/packageLitst.txt
# EOF
