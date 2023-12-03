# `find_clients`

Call this function in for loop. It will return values of all the clients available in source directoy present specified in config file.

```bash
for client in $(find_clients); do
  echo $(basename "$client")
done
```
or

```bash
client_list=($(find_clients))
```

This will return list of clients in variable 


# `is_file_open` 

This function is use to check if there is any open file in system before procedeeing to next command execution in script.

- It takes path of the directory in which we need to check for open files as input and executes `lsof` command on this path. If path is not provided as a input then it takes path from $SOURCE variable. Output of `lsof` is stored in temporary file. 

- Output of `lsof` is then compared with output of aws sync dryrun command to check if any open file from lsof output is present in dryrun commands output.

- After comparing outputs of both commands, **It returns the status code 0 if there are none files open or returns 1 if there are one or files open.**

Call this function inside while loop to continuously check for files as shown in below code. 

```bash
SOURCE="/home/hsg/s3backup/logs"

while true; do
  is_file_open
  if [ $? -eq 0 ]; then
      echo "no files opened now."
      break
  else
      echo "Backup file is currently open. Waiting..."
      sleep 10
  fi
done
```

# `check_aws_cli` 

This function is useful to checks for following 2 things.

1. It checks if aws cli is installed or not.
2. If aws cli is installed properly then it checks for aws credentials.

If one of then is not configured properly then it exits and prvents the further script execution. If both things are configured properly then it returns 0.

To use this function simply call it in you main script before making amy api call to aws.

```bash
check_aws_cli
```


# `format_time_duration` 

This function is used to convert the time duration from seconds to formatted time. It takes time duration in seconds as a input and returns the formatted time. It will format the duration as '**hrs  min  sec**'

```bash
start_time=$(date +%s)
end_time=$(date +%s)
total_time=$(format_time_duration $((end_time - start_time)))

echo $total_time
```
Below is the formatted value after calling this function.

```console
4 hrs 18 min 40 sec
```


# `pre_sync_check`

This function is used determine which files will be synced to the S3 bucket. It compares the path of client on local system with aws S3 bucket and finds if new files are available for sync.

It runs '`aws sync`' command with '`--dryrun`' option and saves the output to `$LOG_FILE` file specified in `start_sync` function.

To use this function call it before starting the actual sync process.

```bash
pre_sync_check
```

*Note : This function should be called within the function `start_sync` as it expects variable values like `$LOG_FILE`, `$SOURCE` and `$CLIENT` already defined.*


# `verify_sync_files`

This function is mainly used to the verify the sync process for given client. It's functionality includes,

- Verifiyng if sync process complteted successfuly or not.

- Verifying the size of synced files to S3 bucket from local file size.

- Sending mail alert according status of sync process.

To use this function call it after sync command execution is completed.

```bash
verify_sync_files
```

*Note : This function should be called within the function `start_sync` as it expects variable values like `$LOG_FILE`, `$SOURCE`, `$PROGRESS_FILE`, `$upload_status`, `$retry_count`, `$mailbody` and `$CLIENT` already defined.*
