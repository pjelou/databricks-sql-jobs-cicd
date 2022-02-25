#/bin/bash
#set -o xtrace
########### Main
while getopts c:e:b:s:p: flag
do
    case "${flag}" in
        c) clustername=${OPTARG};;
        e) envName=${OPTARG};;
        b) branch=${OPTARG};;
        s) soruceDir=${OPTARG};;
        p) profile=${OPTARG};;
    esac
done

databricks jobs configure --version=2.1 --profile ${profile}
envString="_${envName}_"

mkdir tmp
echo "getting clusterid for $clustername"
databricks clusters list  --output JSON --profile ${profile} > tmp/clusters.json
clusterid=$(jq -r --arg clustername "$clustername" '.clusters[] | select (.cluster_name == $clustername).cluster_id' tmp/clusters.json)

if [ -z "${clusterid}" ]
then
    echo "Could not find cluster ${clustername}...exiting" >&2
    exit 2
else
    echo "Cluster id = $clusterid"
fi

echo "Pulling existing jobs list"
databricks jobs list --output JSON --profile ${profile} > tmp/jobs.json

JOBS="${soruceDir}/*.json"

for srcjobfile in $JOBS
do
    echo "Processing $srcjobfile file..."
    jobname=$(jq -r '.name' $srcjobfile)
    # Replace the envname in project-env-job
    newjobname=${jobname/_dev_/$envString}

    echo "  Target job name = ${newjobname}"
    dstJobFile="${newjobname}.json"

    echo "  creating ${newjobname} config file"
    jq --arg newjobname "${newjobname}" '.name = $newjobname' ${srcjobfile} > ${dstJobFile}
    echo "  updating cluster ID to ${clusterid}"
    jq --arg clusterid "${clusterid}" '.tasks[].existing_cluster_id = $clusterid' ${dstJobFile} > ${dstJobFile}.tmp && mv ${dstJobFile}.tmp ${dstJobFile}

    echo "  updating notebook branch to ${branch}"
    jq --arg branch "$branch" '.tasks[].notebook_task.notebook_path |= sub("develop"; $branch)' ${dstJobFile} > ${dstJobFile}.tmp && mv ${dstJobFile}.tmp ${dstJobFile}


    echo "  Deploying ${dstJobFile}"
    echo "  Checking if job ${newjobname} exists"
    jobid=$(jq -r --arg jobname "${newjobname}" '.jobs[] | select (.settings.name == $jobname) | .job_id' tmp/jobs.json)

    if [ -z "$jobid" ]
    then
            echo "  creating new job ${newjobname}"
            databricks jobs create --json-file ${dstJobFile} --profile ${profile}
    else
            echo "  updating existing job $newjobname with id ${jobid}"
            databricks jobs reset --job-id $jobid --json-file ${dstJobFile} --profile ${profile}
    fi
done
