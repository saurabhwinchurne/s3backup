#!/bin/bash
source $(dirname $(pwd))/conf/sync.conf
source $FUNCTIONS

export AWS_PROFILE=$AWS_CLI_PROFILE

if [ ! -d "$REPORT_DIR" ]; then
  mkdir "$REPORT_DIR"
fi

if [ ! -d "$LOG_DIR" ]; then
  mkdir "$LOG_DIR"
fi

start_date=$(date +%F)
start_time=$(date +%s)
log "checking AWS CLI and credentials configuration.."
check_aws_cli

# Check the available clients in source directory for the sync
client_list=($(find_clients))
total_clients=${#client_list[@]}
completed_jobs=0

log "total clients found: $total_clients"

echo $REPORT_FILE_HEADER > $REPORT_FILE

for client in "${client_list[@]}";do
  client=$(basename $client)

  if [ "$MAX_CONCURRENT_UPLOADS" -eq 1 ]; then
    #start_sync $client &
    start_copy $client &
    job_count=$(jobs -p | wc -l)
    echo $job_count > $LOG_DIR/active_jobs.tmp
    job_pid=$(jobs -p)
    wait $job_pid
  else
    # Initiating sync for client each with different process in background
    start_sync $client &
    sleep 2
    job_count=$(jobs -p | wc -l)

    while [ "$job_count" -ge "$MAX_CONCURRENT_UPLOADS" ]; do
      sleep 3
      job_count=$(jobs -p | wc -l)
      echo $job_count > $LOG_DIR/active_jobs.tmp
    done
  fi

done

# Wait for all background sync jobs to finish
wait

end_time=$(date +%s)
total_time=$(format_time_duration $((end_time - start_time)))

send_consolidated_report

log "all sync job completed in $total_time ."
rm -f $LOG_DIR/active_jobs.tmp

# Separate each clients summary log into its individual log folder
for client in "${client_list[@]}";do
  client=$(basename $client)
  grep $client "${LOG_DIR}"/summary.${start_date}.log >> "${LOG_DIR}"/${client}/summary.${client}_${start_date}.log
done
