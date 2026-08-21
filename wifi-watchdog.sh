#!/bin/bash
# --------------------------------------------------------------------------------
#  wifi-watchdog.sh
# --------------------------------------------------------------------------------
#  Raspberry Pi based Kiosks
#
#  Checks network connectivity and reboots the Pi if the network is unreachable.
#  Intended to be run via cron every 15 minutes.
#
#  Version 1
# --------------------------------------------------------------------------------
#  (C) Copyright Gareth Jones - gareth@gareth.com
# --------------------------------------------------------------------------------

PING_HOST="1.1.1.1"
PING_COUNT=4
LOG_FILE="/var/log/wifi-watchdog.log"

# ping the host
if ! ping -c $PING_COUNT $PING_HOST > /dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Network unreachable, rebooting..." >> $LOG_FILE
    sudo /sbin/shutdown -r now
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Network OK" >> $LOG_FILE
fi
