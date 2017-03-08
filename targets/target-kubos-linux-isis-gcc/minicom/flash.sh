#!/bin/bash
# Copyright (C) 2017 Kubos Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Flash files to ISIS OBC board
#

##########################################################################
# Scrape transfer status from minicom log. Looks like this:
# "Bytes Sent: 693248/1769379 BPS:8343 ETA 02:08"
##########################################################################
progress() {
    local line
    while sleep 1; do
        line=$(cat flash.log | grep "Bytes Sent")
        printf "${line}\r"
    done   
}

##########################################################################
# Minicom doesn't allow any pass-through arguments, so instead we need to 
# generate a script for it to run.
#
# Globals:
#   password
#   is_upgrade
# Arguments:
#   name of file
#   path to flash to
# Returns:
#   none
##########################################################################
create_send_script() {
    echo "Sending $1 to $2 on board..."
    cat > send.tmp <<-EOF
verbose on
send root
expect {
    "Password:" break
    timeout 1 break
}
send ${password}
expect {
    "~ #" break
    timeout 5 goto end
}
timeout 3600
send "mkdir -p $2"
send "cd $2"
send "rm $1"
send "rz -w 8192"
! sz -w 8192 $1
if ${is_upgrade} = 1 send "fw_setenv kubos_updatefile $1"
send "exit"
end:
! killall minicom -q
EOF
}

##########################################################################
# Generate a default init script for the new application. 
# File name will be 'S{run_level}{app_name}'
#
# Globals:
#   app_name
#   init_script
# Arguments:
#   none
# Returns:
#   none
##########################################################################
create_init_script() {

    echo "Creating init script"

    # Delete any previous versions of the init script to avoid clutter
    rm -f S*${app_name}

    cat > ${init_script} <<-EOF
#!/bin/sh

NAME=${app_name}
PROG=/usr/sbin/\${NAME}
PID=/var/run/\${NAME}.pid

case "\$1" in
    start)
    echo "Starting \${NAME}: "
    start-stop-daemon -S -q -m -b -p \${PID} --exec \${PROG}
    rc=\$?
    if [ \${rc} -eq 0 ]
    then
        echo "OK"
    else
        echo "FAIL" >&2
    fi
    ;;
    stop)
    echo "Stopping \${NAME}: "
    start-stop-daemon -K -q -p \${PID}
    rc=\$?
    if [ \${rc} -eq 0 ]
    then
        echo "OK"
    else
        echo "FAIL" >&2
    fi
    ;;
    restart)
    "\$0" stop
    "\$0" start
    ;;
    *)
    echo "Usage: \$0 {start|stop|restart}"
    ;;
esac

exit \${rc}
EOF
}

##########################################################################
# Call the minicom transfer script to flash the file
#
# Globals:
#   none
# Arguments:
#   none
# Returns:
#   0 - Transfer successful
#   1 - Transfer failed
##########################################################################
send_file {
    # Run the transfer script
    minicom kubos -o -S send.tmp > flash.log
    
    local retval=1
    
    # Check transfer result
    if grep -q incomplete flash.log; then
        echo "Transfer Failed" 1>&2
    elif grep -q complete flash.log; then
        echo "Transfer Successful"
        retval=0
    elif grep -q incorrect flash.log; then
        echo "Transfer Failed: Invalid password" 1>&2
    else
        echo "Transfer Failed: Connection failed" 1>&2
    fi
    
    return "${retval}"
}

##########################################################################
# Main Script
##########################################################################
main() {
    start=$(date +%s)
    
    this_dir=$(cd "`dirname "$0"`"; pwd)
    name=$(basename $1)
    is_upgrade=0
    is_app=0
    
    password=$(cat yotta_config.json | python -c 'import sys,json; x=json.load(sys.stdin); print x["system"]["password"]')
    dest_dir=$(cat yotta_config.json | python -c 'import sys,json; x=json.load(sys.stdin); print x["system"]["destDir"]')
    init=$(cat yotta_config.json | python -c 'import sys,json; x=json.load(sys.stdin); print x["system"]["initAtBoot"]')
    run_level=$(cat yotta_config.json | python -c 'import sys,json; x=json.load(sys.stdin); print x["system"]["runLevel"]')
    app_name=$(cat ../../module.json | python -c 'import sys,json; x=json.load(sys.stdin); print x["name"]')
    
    init_script="S${run_level}${app_name}"
    
    unamestr=`uname`
    
    if [[ "${unamestr}" =~ "Linux" ]]; then
        device=`lsusb -d '0403:'`
    fi
    
    # Test block. Remove before push
    if [[ "${init}" == "True" ]]; then
        echo "Creating init script"
        #create_init_script
    else
        echo "Not creating init script. ${init}"
    fi
    
    if [[ "${device}" =~ "6001" ]]; then
        echo "Compatible FTDI device found"
        progress &
        progress_pid=$!
        disown
    else
        echo "No compatible FTDI device found" 1>&2
        exit 0
    fi
    
    if [[ "${password}" = "Kubos123" ]]; then
        echo "Using default password"
    fi
    
    if [[ "${name}" = *.itb ]]; then
        path="/upgrade"
        is_upgrade=1
    elif [[ "${name}" != "${app_name}" ]]; then
        path="${dest_dir}"
    else
        path="/home/usr/bin"
        is_app=1
    fi
    
    # Send the file
    create_send_script ${name} ${path}
    send_file
    retval=$?
    
    # If necessary, send init script
    if [[ "${retval}" = 0 && "${is_app}" = 1 && "${init}" = "True" ]]; then
        rm send.tmp
        create_init_script
        create_send_script ${init_script} /home/etc/init.d
        send_file
        retval=$?
    fi
    
    # Cleanup
    rm send.tmp
    stty sane
    kill ${progress_pid}
    
    # Print exec time
    end=$(date +%s)
    runtime=$(expr ${end} - ${start})
    echo "Execution time: $runtime seconds"
    
    exit ${retval}
}

main "$@"
