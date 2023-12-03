#!/bin/bash

log() {
  echo [$(date '+%a %F %X %Z')] ["$CLIENT"] "$@" >>"${LOG_DIR}"/summary.${start_date}.log
}

regular_alert() {
  cat <<EOF | /usr/sbin/sendmail -t
To:$EMAIL_RECIPIENTS
From:$EMAIL_SENDER
Subject:$REGULAR_ALERT_SUBJECT $CLIENT $start_date

Host:   $(hostname)

$(echo -e "$1")
EOF
  rm -f "$mailbody"
}

critical_alert() {
  cat <<EOF | /usr/sbin/sendmail -t
To:$EMAIL_RECIPIENTS
From:$EMAIL_SENDER
Subject:$CRITICAL_ALERT_SUBJECT $CLIENT $start_date
X-Priority: 1
Priority: Urgent
Importance: high

Host:   $(hostname)

$(echo -e "$1")
EOF
  rm -f "$mailbody"
}

check_aws_cli() {
  if ! command -v aws &>/dev/null; then
    log "AWS CLI is not installed. Please install the AWS CLI and try again."
    exit 1
  fi

  if ! aws configure get aws_access_key_id &>/dev/null; then
    log "AWS credentials are not configured. Please configure AWS credentials using and try again."
    exit 1
  fi

  if ! command -v s3cmd &>/dev/null; then
    log "s3cmd is not installed. Please install the s3cmd and try again."
    exit 1
  fi

  log "AWS CLI and credentials are properly configured."
  return 0
}

format_time_duration() {
  input_seconds=$1
  hours=$((input_seconds / 3600))
  minutes=$(((input_seconds % 3600) / 60))
  seconds=$((input_seconds % 60))

  if ((hours > 0)); then
    echo "$hours hrs $minutes min $seconds sec"
  elif ((minutes > 0)); then
    echo "$minutes min $seconds sec"
  else
    echo "$seconds sec"
  fi
}

is_file_open() {
  # Check if any file is being accessed by any process from given path
  tmp_openfile="/tmp/openfiles_$(date '+%Y%m%d%H%M%S').tmp"

  source_path=${1}
  if [ "${source_path}" == '' ]; then
    #log "source path is not given as input while calling the function. taking $SOURCE as source path."
    source_path=$SOURCE
  else
    source_path=${1}
  fi

  lsof +D "$source_path" | grep "REG" >"$tmp_openfile"

  if [ -z "$(cat "$tmp_openfile")" ]; then
    log "None of the file be synced to S3 is opened at the moment for client $CLIENT"
    open_file_status=false
  fi

  for lsof_filename in $(awk '/REG/ {print $NF}' "$tmp_openfile"); do
    grep -qF $(basename "$lsof_filename") "$LOG_FILE"
    if [ $? -eq 0 ]; then
      log "file $lsof_filename is currently opened in system!"
      open_file_status=true
    fi
  done

  if [ "$open_file_status" = true ]; then
    #echo "At least one opened file was found."
    rm -f "$tmp_openfile"
    return 1
  else
    rm -f "$tmp_openfile"
    return 0
  fi
}

is_volume_open() {
  vol_name=${1}
  if [ "${vol_name}" == '' ]; then
    log "volume name is not given as input while calling the function!"
    exit 1
  fi

  lsof $vol_name
  open_vol_status=$?

  if [ ${open_vol_status} = "0" ]; then
    log "Volume $vol_name is currently opened in system!"
  else
    log "Volume $vol_name is not open at the moment by any process."
  fi

  return $open_vol_status
}

find_clients() {
  log "checking if source directory exists"
  if [ -d "$SOURCE_DIR" ]; then
    log "source directory exists $SOURCE_DIR"
    log "Finding all the clients available for sync..."

    cd $SOURCE_DIR || exit

    if [ "$SELECT_CLIENT_MODE" = "include" ]; then
      CLIENTS=$(ls -1d */ | grep -E "$SELECT_CLIENT_PATTERN")
    elif [ "$SELECT_CLIENT_MODE" = "exclude" ]; then
      CLIENTS=$(ls -1d */ | grep -Ev "$SELECT_CLIENT_PATTERN")
    else
      CLIENTS=$(ls -1d */)
    fi

    if [ -z "$CLIENTS" ]; then
      log "zero clients found from source path $SOURCE_DIR. exiting the script."
      exit 0
    else
      log "Clients found: $(echo "$CLIENTS")"
      echo "$CLIENTS"
    fi

  else
    log "source directory $SOURCE_DIR does not exists, please check and try agian!"
    exit 1
  fi
}

pre_sync_check() {
  log "pre checking the files available for sync"
  #s3cmd sync --dry-run --no-check-md5 --stat --preserve --verbose --exclude '*' --include '*L0*/*L0*' "$SOURCE" s3://"$S3_BUCKET"/"$PREFIX"/"$CLIENT"/ >>"$LOG_FILE" 2>&1
  s3cmd sync --dry-run --no-check-md5 --stats --preserve --verbose --exclude '*' --include $PATH_PATTERN "$SOURCE" s3://"$S3_BUCKET"/"$PREFIX"/"$CLIENT"/ >>"$LOG_FILE" 2>&1
  pre_check_status=$?

  if [ $pre_check_status -eq 0 ]; then

    if ! grep -E "^upload:" "$LOG_FILE" | sort -u; then
      log "No new files are available to sync for client $CLIENT as of now."
      log "Source directory $SOURCE is in sync with S3."
    else
      log "Below files will be synced to S3"
      log "$(cat "$LOG_FILE" | grep -E "^upload:" | sort -u)"
    fi
    return 0
  else
    log "something went wrong while pre checking $CLIENT clients source directory."
    log "aws cli command exited with status code $pre_check_status"
    log "aborting the process!"
    exit 1
  fi
}

verify_sync_files() {
  # Verify sync status and file size
  if [ "$upload_status" -eq 0 ]; then
    log "Sync successful in attempt $retry_count"
    log "Total Time: $total_time seconds"

    echo "Sync Status  : Successful" >> "$mailbody" 
    echo "Sync Attempt : $retry_count" >> "$mailbody"
    echo "Start Time   : $sync_start_time" >> "$mailbody"
    echo "End Time     : $sync_end_time" >> "$mailbody" 
    echo "Total Time   : $total_time" >> "$mailbody"

    total_data_transferred=0

    #filter synced files from progress log file
    #grep -oP 'upload:.*?s3://\S+' "$PROGRESS_FILE" >>"$LOG_FILE"
    uploaded_files=$(grep -oP 'upload:.*?s3://\S+' "$PROGRESS_FILE" | sort -u)

    if ! echo "$uploaded_files" | grep -Eq "^upload"; then
      echo "No new files to sync. Source directory $SOURCE is in sync with S3." >>"$mailbody"
    else
      echo "\n Below files sync to S3 \n" >>"$mailbody"
      for FILE in $(echo "$uploaded_files" | grep -E "^upload:" | awk '{print $2}'); do
        #FILE_NAME=$(basename "$FILE" | tr -d '\047')
        FILE=$(echo $FILE | tr -d \')
        FILE_NAME=$(basename $FILE)
        OBJECT_KEY="${FILE#$SOURCE_DIR/}"

        local_size=$(ls -l $FILE | awk '{print $5}')
        uploaded_size=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$PREFIX/$OBJECT_KEY" --query 'ContentLength' --output text)
        uploaded_size="${uploaded_size//\"/}"

        total_data_transferred=$((total_data_transferred + uploaded_size))

        if [ "$local_size" == "$uploaded_size" ]; then
          echo "\n$FILE   -   $uploaded_size Bytes" >>"$mailbody"
          log "$FILE - File size verification successful"
        else
          echo "\n$FILE   -   $uploaded_size Bytes" >>"$mailbody"
          log "$FILE - File size verification failed"
        fi
      done
    fi

    echo "\n\nTotal Data Transferred : $total_data_transferred Bytes" >>"$mailbody"

    # Send email alert
    regular_alert "$(cat "$mailbody")"
  else
    log "Sync failed for client $CLIENT for attempt $retry_count!"

    echo "Sync Status:  Failed \n" >>"$mailbody"
    echo "Sync Attempt:  $retry_count" >>"$mailbody"
    echo "ERROR Message: \n" >>"$mailbody"
    echo "Please check the log file $LOG_FILE for more details." >>"$mailbody"

    # Send email alert
    critical_alert "$(cat "$mailbody")"
  fi
}

verify_copied_file() {
  file=$1
  file_name=$(basename $file)
  local_size=$(ls -l $file | awk '{print $5}')
  OBJECT_KEY="${file#$SOURCE_DIR/}"

  uploaded_size=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$PREFIX/$OBJECT_KEY" --query 'ContentLength' --output text)
  uploaded_size="${uploaded_size//\"/}"

  if [ "$local_size" == "$uploaded_size" ]; then
    log "$file - File size verification successful"
    echo "successfull"
  else
    log "$file - File size verification failed"
    echo "failed"
  fi
}

generate_mail() {
  log "Sync successful in attempt $retry_count"
  log "Total Time: $total_time seconds"

  # echo "<p>" >> "$mailbody"
  # echo "Start Time   :  $(date -d "@$client_copy_start_time")" >> "$mailbody"
  # echo "End Time     :  $(date -d "@$client_copy_end_time")" >> "$mailbody" 
  # echo "Total Time   :  $total_client_copy_time" >> "$mailbody"
  # echo "</p>" >> "$mailbody"

  echo "From: $EMAIL_SENDER" >>$mailbody
  echo "To: $EMAIL_RECIPIENTS" >>$mailbody
  echo "Content-type: text/html" >>$mailbody
  echo "Subject: $REGULAR_ALERT_SUBJECT $CLIENT $start_date" >>$mailbody
  echo "
    <html>
      <body>
	Host         :  $(hostname)<br>
        Start Time   :  $(date -d "@$client_copy_start_time")<br>
        End Time     :  $(date -d "@$client_copy_end_time")<br>
        Total Time   :  $total_client_copy_time<br><br>

        <table border=2>
          <tr>
            <th nowrap="nowrap">Volume Name</th>
            <th nowrap="nowrap">Size</th>
            <th nowrap="nowrap">Copy Status</th>
            <th nowrap="nowrap">Verification Status</th>
            <th nowrap="nowrap">Retries</th>
            <th nowrap="nowrap">S3 Location</th>
            <th nowrap="nowrap">Start Time</th>
            <th nowrap="nowrap">End Time</th>
            <th nowrap="nowrap">Total Time</th>
          </tr>
    " >> "$mailbody"

  total_data_transferred=0
  exec < $REPORT_FILE
  read header
  while IFS="," read -r Volume_Name Size Copy_Status Verification_Status Retries S3_Location Start_Time End_Time Total_Time
  do
    if echo $Volume_Name | grep $CLIENT; then
      echo "
          <tr>
            <td nowrap="nowrap">$Volume_Name</td>
            <td nowrap="nowrap">$Size Bytes</td>
            <td nowrap="nowrap">$Copy_Status</td>
            <td nowrap="nowrap">$Verification_Status</td>
            <td nowrap="nowrap">$Retries</td>
            <td nowrap="nowrap">$S3_Location</td>
            <td nowrap="nowrap">$Start_Time</td>
            <td nowrap="nowrap">$End_Time</td>
            <td nowrap="nowrap">$Total_Time</td>
          </tr>
      " >> "$mailbody"
      total_data_transferred=$((total_data_transferred + Size))
    fi
  done
  
  echo "    </table>
              <br>
              Total Data Transferred : $total_data_transferred Bytes
              </body>
                </html>
        " >> "$mailbody"

  #echo "\n\nTotal Data Transferred : $total_data_transferred Bytes" >>"$mailbody"

  # Send email alert
  #regular_alert "$(cat "$mailbody")"
  cat $mailbody | sendmail -t
  rm -f $mailbody
}

send_consolidated_report() {
  if [ -f "$REPORT_FILE" ]; then
    log "sending consolidated report mail to recipients."
    set from = $EMAIL_SENDER
    #echo -e "Hi Team, \n\nAll the sync Job completed for the date $(date +%F). \nStart Time: $(date -d "@$start_time") \nEnd Time: $(date -d "@$end_time") \nTotal Time: $total_time \n\nThank You" | mutt -s "Bacula S3 Consolidated Report - $(hostname)" -a $REPORT_FILE -- $EMAIL_RECIPIENTS 

    cat << EOF | mutt -s "Bacula S3 Consolidated Report - $(hostname)" -a $REPORT_FILE -- $EMAIL_RECIPIENTS
    Hi Team,

    All the sync Job completed for the date $(date +%F).

    Start Time  -   $(date -d "@$start_time")
    End Time    -   $(date -d "@$end_time")
    Total Time  -   $total_time

    Thank You    
EOF
  else
    log "$REPORT_FILE does not exist. failed sent consolidated report mail."
  fi
}

get_bandwidth_limit() {
  cd $SOURCE_DIR || exit
  total_jobs=$(ls -1d */ | grep -Ev "$EXCLUDE_CLIENTS" | wc -l)
  running_jobs=$(cat $LOG_DIR/active_jobs.tmp) # find currently running sync jobs started by main script
  remianing_jobs=$((total_jobs - completed_jobs))

  if [ $remianing_jobs -lt $MAX_CONCURRENT_UPLOADS ] && [ $running_jobs -lt $((MAX_CONCURRENT_UPLOADS - 1)) ]; then
    bw_limit=$((MAX_BANDWIDTH / remianing_jobs))
    echo $bw_limit
  else
    bw_limit=$((MAX_BANDWIDTH / MAX_CONCURRENT_UPLOADS))
    echo "$bw_limit"
  fi
}

start_sync() {
  CLIENT="$1"
  CLIENT_LOG_DIR="$LOG_DIR/$CLIENT/"

  if [ ! -d "$CLIENT_LOG_DIR" ]; then
    mkdir "$CLIENT_LOG_DIR"
  fi

  mailbody=/tmp/mail_body_$CLIENT
  LOG_FILE="$CLIENT_LOG_DIR/sync_status_$CLIENT-$(date '+%Y%m%d_%H%M%S').log"
  PROGRESS_FILE="$CLIENT_LOG_DIR/sync_progress_$CLIENT-$(date '+%Y%m%d_%H%M%S').log"
  SOURCE="$SOURCE_DIR/$CLIENT/"
  DESTINATION="s3://$S3_BUCKET/$PREFIX/$CLIENT/"

  # Sync file to S3 bucket
  log "starting the sync for client $CLIENT ..."
  retry_count=0
  while [ $retry_count -le "$SYNC_RETRY" ]; do

    # running pre_sync_check to check avaiable files before starting the sync for client
    pre_sync_check

    # check for any open files with is_file_open function
    log "checking for the open files before staring the sync process."
    while true; do
      is_file_open

      if [ $? -eq 0 ]; then
        log "no files opened now."
        break
      else
        log "Backup file is currently open. Waiting 60 seconds..."
        sleep 60
      fi
    done

    sleep 10
    log "calculating the bandwidth limit to be set for sync process..."
    bandwidth=$(get_bandwidth_limit)
    log "setting bandwidth limit of $bandwidth KB/s for sync process"

    start_time=$(date +%s)
    sync_start_time=$(date -d "@$start_time")

    s3cmd sync --no-check-md5 --verbose --stats --progress --preserve --multipart-chunk-size-mb=$MULTIPART_CHUNK_SIZE --limit-rate=${bandwidth}k --exclude '*' --include $PATH_PATTERN "$SOURCE" "$DESTINATION" >> "$PROGRESS_FILE" 2>>"$LOG_FILE"
    upload_status=$?

    end_time=$(date +%s)
    sync_end_time=$(date -d "@$end_time")
    total_time=$(format_time_duration $((end_time - start_time)))

    if [ $upload_status -eq 0 ]; then
      log "sync completed for client $CLIENT in attempt $retry_count and $total_time ."
      verify_sync_files
      completed_jobs=$((completed_jobs + 1))
      break
    else
      retry_count=$((retry_count + 1))
      log "sync failed for client $CLIENT. Retrying for attempt $retry_count..."
      critical_alert "\nSync Status:  Failed\nSync Attempt:  $retry_count\n\nSync failed for attempt $retry_count for the client $CLIENT. Retrying agian in 1 minute.\n\nThank You"
      sleep 60
    fi
  done

  if [ "$upload_status" -ne 0 ]; then
    log "sync failed after $SYNC_RETRY retires."
    critical_alert "\nSync Status:  Failed\n\nSync failed after $SYNC_RETRY retires for the client $CLIENT. No more retires after this. Check the script exection logs for further details.\n\nThank You"
  fi

  return "$upload_status"
}

start_copy() {
  CLIENT="$1"
  CLIENT_LOG_DIR="$LOG_DIR/$CLIENT/"

  if [ ! -d "$CLIENT_LOG_DIR" ]; then
    mkdir "$CLIENT_LOG_DIR"
  fi

  mailbody=/tmp/mail_body_$CLIENT
  LOG_FILE="$CLIENT_LOG_DIR/copy_status_$CLIENT-$(date '+%Y%m%d_%H%M%S').log"
  PROGRESS_FILE="$CLIENT_LOG_DIR/copy_progress_$CLIENT-$(date '+%Y%m%d_%H%M%S').log"
  SOURCE="$SOURCE_DIR/$CLIENT/"
  DESTINATION="s3://$S3_BUCKET/$PREFIX/$CLIENT"

  # running pre_sync_check to check avaiable files before starting the sync for client
  pre_sync_check

  # Copy file to S3 bucket
  log "starting the copy for the $CLIENT ..."
  client_copy_start_time=$(date +%s)

  volumes=$(grep -E "^upload:" "$LOG_FILE" | sort -u | awk '{print $2}')

  #add logic to check if $volumes is empty and local folder and s3 folder is in sync, if yes send notification accordingly

  for volume in $volumes; do 
    volume=$(echo $volume | tr -d \')
    volume_name=$(basename $volume)
    local_size=$(ls -l $volume | awk '{print $5}')
    retry_count=0

    while [ $retry_count -le "$SYNC_RETRY" ]; do
      # check for any open files with is_file_open function
      log "checking if volume $volume_name is opend by process."
      while true; do
        is_volume_open $volume

        if [ $? -eq 1 ]; then
          log "no volume opened now."
          break
        else
          log "Backup volume $volume_name is currently open. Waiting 60 seconds..."
          sleep 60
        fi
      done

      sleep 10
      log "calculating the bandwidth limit to be set for sync process..."
      bandwidth=$(get_bandwidth_limit)
      log "setting bandwidth limit of $bandwidth KB/s for sync process"

      start_time=$(date +%s)
      copy_start_time=$(date -d "@$start_time")

      s3cmd put --no-check-md5 --verbose --stats --progress --preserve --multipart-chunk-size-mb=$MULTIPART_CHUNK_SIZE --limit-rate=${bandwidth}k "$volume" "$DESTINATION/$volume_name" >> "$PROGRESS_FILE" 2>>"$LOG_FILE"
      upload_status=$?

      end_time=$(date +%s)
      copy_end_time=$(date -d "@$end_time")
      total_time=$(format_time_duration $((end_time - start_time)))

      if [ $upload_status -eq 0 ]; then
        log "Copy completed for the volume $volume_name in attempt $retry_count and $total_time ."
        verification=$(verify_copied_file $volume)
        echo "$volume,$local_size,sucessfull,$verification,$retry_count,$DESTINATION/$volume_name,$copy_start_time,$copy_end_time,$total_time" >> $REPORT_FILE
        completed_jobs=$((completed_jobs + 1))
        break
      else
        retry_count=$((retry_count + 1))
        log "copy failed for voume $volume_name. Retrying for attempt $retry_count..."
        critical_alert "\Copy Status:  Failed\nCopy Attempt:  $retry_count\n\nCopy failed for attempt $retry_count for the volume $volume. Retrying agian in 1 minute.\n\nThank You"
        sleep 60
      fi
    done

    if [ "$upload_status" -ne 0 ]; then
      log "Copy failed for voume $volume after $SYNC_RETRY retires."

      critical_alert "\nCopy Status:  Failed\n\nCopy failed after $SYNC_RETRY retires for the client $CLIENT and volume $volume. No more retires after this. Check the script exection logs for further details.\n\nThank You"

      echo "$volume,$local_size,failed,failed,$retry_count,$DESTINATION/$volume_name,$copy_start_time,$copy_end_time,$total_time" >> $REPORT_FILE
    fi

  done

  client_copy_end_time=$(date +%s)
  total_client_copy_time=$(format_time_duration $((client_copy_end_time - client_copy_start_time)))
  generate_mail
}
