#/bin/bash
#set -o xtrace
########### Main
while getopts c:p: flag
do
    case "${flag}" in
        c) configFile=${OPTARG};;
        p) profile=${OPTARG};;
    esac
done

rm -rf jobs/src
rm -rf *.json
mkdir jobs/src

databricks jobs configure --version=2.1 --profile ${profile}
echo "Getting list of existing jobs for 2.0 API"
databricks jobs list --output JSON --profile ${profile} --version 2.0 > jobs2.0.json
echo "Getting list of existing jobs for 2.1 API"
databricks jobs list --output JSON --profile ${profile} --version 2.1 > jobs2.1.json
jq -c -r '.jobs[]' $configFile |
while IFS=$"\n" read -r jobname; do
   echo "Processing job ${jobname}"
   apiversion="2.1"
   jobid=$(jq -r --arg jobname ${jobname} '.jobs[] | select (.settings.name == $jobname).job_id' jobs2.1.json)

   if [ -z "${jobid}" ]
   then
      echo "   Could not find job id for job ${jobname} using API 2.1... trying API 2.0"
      apiversion="2.0"
      jobid=$(jq -r --arg jobname ${jobname} '.jobs[] | select (.settings.name == $jobname).job_id' jobs2.0.json)

      if [ -z "${jobid}" ]
      then
         echo "   Could not find job id for job ${jobname} using API 2.0. Check job name and permissions" >&2
         exit 2
      else
         echo "   Job id of ${jobname} is ${jobid} using API 2.0"
         apiversion="2.0"
      fi
   else
      echo "   Job id of ${jobname} is ${jobid} using API 2.1"
   fi

   jobFilePath="jobs/src/${jobname}.json"
   echo "   Saving job config to file ${jobFilePath}"
   databricks jobs get --job-id ${jobid} --profile ${profile} --version ${apiversion} | jq -r '.settings | .job_clusters = []' > ${jobFilePath}
done

#rm -rf *.json