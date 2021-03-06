#!/bin/bash

    kill -9 `ps aux | grep "userver.pl" | grep -v grep | tr -s ' ' '+' | cut -d+ -f2` 2> /dev/null
    kill -9 `ps aux | grep "check.pl" | grep -v grep | tr -s ' ' '+' | cut -d+ -f2`  2> /dev/null
    rm -f /var/run/userver/lock;
    rm -f /var/run/userver/pipe;
    if ! [ -d /var/run/userver ];
    then
        mkdir -m 766 /var/run/userver
    fi
    /bin/echo `/bin/date` $* >> /home/solenkov.v/UServer/launch/restart
    /home/solenkov.v/UServer/userver.pl &
