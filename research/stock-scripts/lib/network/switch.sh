#!/bin/sh
# Copyright (C) 2009 OpenWrt.org

setup_switch_dev() {
	local name
	config_get name "$1" name
	name="${name:-$1}"
	[ -d "/sys/class/net/$name" ] && ifconfig "$name" up
	swconfig dev "$name" load network
}

force_enable_flowctrl() {
	ssdk_sh << EOF &>/dev/null
device id set 0
port flowCtrlforcemode set 1 enable
port flowCtrl set 1 enable
port flowCtrlforcemode set 2 enable
port flowCtrl set 2 enable
port flowCtrlforcemode set 3 enable
port flowCtrl set 3 enable
port flowCtrlforcemode set 4 enable
port flowCtrl set 4 enable
port flowCtrlforcemode set 5 enable
port flowCtrl set 5 enable
q
EOF
	ssdk_sh << EOF &>/dev/null
device id set 1
port flowCtrlforcemode set 1 enable
port flowCtrl set 1 enable
port flowCtrlforcemode set 2 enable
port flowCtrl set 2 enable
port flowCtrlforcemode set 3 enable
port flowCtrl set 3 enable
port flowCtrlforcemode set 4 enable
port flowCtrl set 4 enable
port flowCtrlforcemode set 5 enable
port flowCtrl set 5 enable
port flowCtrlforcemode set 6 enable
port flowCtrl set 6 enable
q
EOF
}

setup_switch() {
	config_load network
	config_foreach setup_switch_dev switch

	# Update default group vlan tag for our design
	echo 2 > /proc/sys/net/edma/default_group1_vlan_tag
	echo 1 > /proc/sys/net/edma/default_group2_vlan_tag
	echo 3 > /proc/sys/net/edma/default_group3_vlan_tag

	force_enable_flowctrl
}
