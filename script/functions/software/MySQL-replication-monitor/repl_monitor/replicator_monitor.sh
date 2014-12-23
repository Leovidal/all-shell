#!/bin/bash

# sorces included
source monitor_constant.sh    || exit 2
source monitis_util.sh		  || exit 2

declare -i initialized=0	# indicator of master variables initializing
#previous measurement data
declare -i prev_Slave_read_binlog_num=0
declare -i prev_Slave_read_binlog_pos=0
declare -i prev_Master_binlog_num=0
declare -i prev_Master_binlog_pos=0
declare -i prev_time=0
declare    return_value

#Access to the MySQL located on remout host via SSH, 
# execute command and keep the result in the local file
#
#@param HOST {STRING} - remote host IP where MySQL is located
#@param PORT {INT} - remote MySQL listen port
#@param USER {STRING} - MySQL user name
#@param PSWD {STRING} - MySQL user password
#@param CMD {STRING} - executed command on remote MySQL
#@param FILE {STRING} - file that receive the results
function access_remout_MySQL {
	local HOST=$1
	local PORT=$2
	local USER=$3
	local PSWD=$4
	local CMD=$5
	local FILE=$6
	local MYSQL="mysql -u $USER -p$PSWD -h localhost -P $PORT"
	local SSH="ssh -f -L 3307:localhost:$PORT $USER@$HOST"
	$SSH "$MYSQL -e \"$CMD\" " | tee $FILE > /dev/null
	local ret="$?"
	if [[ ($ret -gt 0) ]]
	then
		return 1
	fi
	return $ret
}

#  Format a timestamp into the form 'x day hh:mm:ss'
#  
#  @param TIMESTAMP {NUMBER} the timestamp in sec
# 
function formatTimestamp(){
	local time="$1"
	local sec=$(( $time%60 ))
	local min=$(( ($time/60)%60 ))
	local hr=$(( ($time/3600)%24 ))
	local da=$(( $time/86400 ))
	local str=$(echo `printf "%02u:%02u:%02u" $hr $min $sec`)
	if [[ ($da -gt 0) ]] ; then
		str="$da-$str" 
	fi
	echo $str
}

#Function returns variable value from file
#
#@param FILENAME {STRING} - relative or absolute path to file 
#							where beforehand stored the variables set
#@param VAR {STRING} - searching variable name
#@param DELIMITER {CHAR} - separating delimiter
#sample:
#   $(extract_value mstatus auto_increment_offset)
function extract_value() {
    FILENAME=$1
    VAR=$2
    DELIMITER=$3
    if [ $DELIMITER ] ; then
	    ret=`grep -w $VAR $FILENAME | awk -F $DELIMITER '{print $2 $3} ' `
    else
	    ret=`grep -w $VAR $FILENAME | awk '{print $2 $3} ' `
    fi
    echo `trim "$ret"`
}

function get_measure() {
	MSG="OK"
	local errors=0

	#echo "********** check Slave parameters **********"
	access_remout_MySQL $SLAVE_HOST $SLAVE_PORT $SLAVE_USER $SLAVE_PASSWORD  "SHOW SLAVE STATUS\G" sstatus
	local ret_s="$?"
	if [[ (ret_s -gt 0) || ($(stat -c%s sstatus) -le 0) ]] ; then
		MSG="Unknown problems while access SLAVE mysql..."
	  	details="$(uri_escape \"details\":\"Problems in replication - $MSG\")"
	    return_value="$RESP_DOWN;additionalResults:[{$details}]"
		return 1
	fi
	
	#echo "********** check Master parameters **********"
	access_remout_MySQL $MASTER_HOST $MASTER_PORT $MASTER_USER $MASTER_PASSWORD  "SHOW MASTER STATUS\G" mstatus
	local ret_m="$?"
	if [[ (ret_m -gt 0) || ($(stat -c%s mstatus) -le 0) ]]
	then
		MSG="Unknown problems while access MASTER mysql..."
	  	details="$(uri_escape \"details\":\"Problems in replication - $MSG\")"
	    return_value="$RESP_DOWN;additionalResults:[{$details}]"
		return 1
	fi

	#****Still OK****
	if [ $initialized -eq 0 ]
	then
	  access_remout_MySQL $MASTER_HOST $MASTER_PORT $MASTER_USER $MASTER_PASSWORD  "SHOW VARIABLES" mvariables
	  initialized=1
	fi
	
	
	#echo "*********** Retriving data for Master ***********"
	local Max_binlog_size=$(extract_value mvariables max_binlog_size )
	local Master_binlog_file=$(extract_value mstatus File )
	local Master_binlog_num=$(echo "obase=10;${Master_binlog_file##*.}" | bc )
	local Master_binlog_pos=$(extract_value mstatus Position )
	
	#echo "*********** Retriving data for Slave ***********"
	local Master_Host=$(extract_value sstatus Master_Host)
	local Master_Port=$(extract_value sstatus Master_Port)
	local Slave_read_binlog_file=$(extract_value sstatus Master_Log_File)
	local Slave_read_binlog_num=$(echo "obase=10;${Slave_read_binlog_file##*.}" | bc )
	local Slave_read_binlog_pos=$(extract_value sstatus Exec_Master_Log_Pos)
	local Slave_IO_Running=$(extract_value sstatus Slave_IO_Running)
	local Slave_SQL_Running=$(extract_value sstatus Slave_SQL_Running)
	local Slave_seconds_behind_master=$(extract_value sstatus Seconds_Behind_Master)
	local Slave_last_errno=$(extract_value sstatus Last_Errno)
	local Slave_last_error=$(extract_value sstatus Last_Error :)
	local time_stamp=`date -u +%s` 		#current timestamp in sec
	
	# load factor calculation [positions/sec]
	local Master_load=0
	local Slave_load=0
	local discord=0
	if [ $prev_time -gt 0 ] ; then
		local Master_load=$(echo "scale=2;($Master_binlog_pos-$prev_Master_binlog_pos+$Max_binlog_size*($Master_binlog_num-$prev_Master_binlog_num))/($time_stamp-$prev_time)" | bc )
		local Slave_load=$(echo "scale=2;($Slave_read_binlog_pos-$prev_Slave_read_binlog_pos+$Max_binlog_size*($Slave_read_binlog_num-$prev_Slave_read_binlog_num))/($time_stamp-$prev_time)" | bc )
		if [ $(echo "$Master_load > 0" | bc ) -ne 0 ] ; then			
			local discord=$(echo "scale=2;100*(1 - $Slave_load / $Master_load)" | bc )
		fi
	fi
	
	prev_Master_binlog_num=$Master_binlog_num
	prev_Master_binlog_pos=$Master_binlog_pos

	prev_Slave_read_binlog_num=$Slave_read_binlog_num
	prev_Slave_read_binlog_pos=$Slave_read_binlog_pos
	prev_time=$time_stamp
	
	local dev=$(( $Master_binlog_pos + $Max_binlog_size *($Master_binlog_num -  $Slave_read_binlog_num) ))
	if [ $dev -ne 0 ] ; then
		local Desynch_percent=$(echo "scale=2;100*(1 - $Slave_read_binlog_pos / $dev)" | bc ) 
	else
		local Desynch_percent=$dev
	fi
	
	#echo "*********** Analizing ****************"
	local alive=yes;
	
	if [ "$Master_Host" != "$MASTER_HOST" ]
	then
	    MSG[$errors]="ERROR - the slave is replicating not from the defined host"
	    errors=$(($errors+1))
	    alive=no
	fi
	
	if [ "$Master_Port" != "$MASTER_PORT" ]
	then
	    MSG[$errors]="ERROR - the slave listen not the defined host port"
	    errors=$(($errors+1))
	    alive=no
	fi
	
	if [ "$Master_binlog_file" != "$Slave_read_binlog_file" ]
	then
	    MSG[$errors]="CRITICAL - master binlog ($Master_binlog_file) and slave read binlog ($Slave_read_binlog_file) files differ"
	    errors=$(($errors+1))
	    alive=no
	fi
	
	if [ "$Slave_IO_Running" == "No" ]
	then
	    MSG[$errors]="CRITICAL - Replication is stopped (IO_Thread is down)"
	    errors=$(($errors+1))
	    alive=no
	fi
	
	if [ "$Slave_SQL_Running" == "No" ]
	then
	    MSG[$errors]="CRITICAL - Replication is stopped (SQL_THread is down) "
	    errors=$(($errors+1))
	    alive=no
	fi
	
	if [ $Slave_seconds_behind_master -gt 0 ]
	then
	    MSG[$errors]="WARNING - Slave is behind of Master at about $Slave_seconds_behind_master seconds"
	    errors=$(($errors+1))
	fi
	
	if [ $(echo "$Desynch_percent > 1" | bc ) -ne 0 ]
	then
	    MSG[$errors]="WARNING - Desynchronization in replication is about $Desynch_percent percent"
	    errors=$(($errors+1))
	fi
	
	if [ $(echo "$discord > 5 || $discord < -5" | bc ) -ne 0 ]
	then
	    MSG[$errors]="WARNING - Inconsistency in replication has reached to $discord percent \(master - $Master_load; slave - $Slave_load \)"
	    errors=$(($errors+1))
	fi
	
	if [[ ($errors -gt 0) ]] ; then
	    details={"$(uri_escape \"details\":\"Problems in replication\")"}
	    CNT=0
	    while [[ ("$CNT" != "$errors") ]] ; do
	        details=$details,{"$(uri_escape \"details\":\"${MSG[$CNT]}\")"}
	        CNT=$(($CNT+1))
	    done
	else
	    details={"$(uri_escape \"details\":\"Replication OK\")"}
	    details=$details,{"$(uri_escape \"details\":\"Master writes to $Master_binlog_file \($Master_binlog_pos\) with rate $Master_load pos/sec\")"}
	    details=$details,{"$(uri_escape \"details\":\"Slave reads from $Slave_read_binlog_file \($Slave_read_binlog_pos\) with rate $Slave_load pos/sec\")"}
	fi
	local param="alive:$alive;late:$Slave_seconds_behind_master;desynch:$Desynch_percent;last_errno:$Slave_last_errno;discord:$discord;additionalResults:[$details]"
	return_value="$param"
	return 0
}

#get_measure
#echo $return_value
