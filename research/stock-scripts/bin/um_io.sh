#!/bin/sh
#
# Copyright (C) 2017, U-MEDIA Communications
# All Rights Reserved.
#

gpio_config()
{
	echo "Init GPIO"
	
	# Direction
	um_gpio set_gpio_dir 18 in
	um_gpio set_gpio_dir 34 in #Reset Button
	um_gpio set_gpio_dir 48 out
	um_gpio set_gpio_dir 50 out #WPS LED
	
	# High / Low
	um_gpio set_gpio 48 high #pull high for usb storage disk
	um_gpio set_gpio 50 High
}

add_permissions()
{
	chmod +s /bin/busybox
	sync
}

passwd_check()
{
	if [ ! -e "/etc/passwd" ]; then
		cp -r /etc/passwd- /etc/passwd
	elif [ `ls -lah "/etc/passwd" | awk '{ print $5}'` -lt 10 -o -z `grep  '^root:' /etc/passwd | cut -d: -f1` ]; then
		cp -r /etc/passwd- /etc/passwd
	fi
}

init()
{
	gpio_config
	add_permissions
	passwd_check
}

${1}
