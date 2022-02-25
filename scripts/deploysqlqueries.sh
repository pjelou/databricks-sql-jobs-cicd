#set -o xtrace
function deployquery ()
{
   local sourcequeryname=$1
   local shortQueryName=$(echo ${sourcequeryname} |cut -f 2- -d '_')
   local destqueryname="${envName}_${shortQueryName}"
   echo "   Deploying as "$destqueryname
   local querySourceFile="${soruceDir}/${shortQueryName}.json"

   # Check that query file exists
   if [ -f "$querySourceFile" ]; then
      echo "   $querySourceFile exists."
   else
      echo "   ${querySourceFile} not found"
      echo "   Could not find query file for ${sourcequeryname} named   in ${soruceDir}"
      echo "   Check that the query definition exists in direcoty"
      echo "   ${querySourceFile} not found" >&2
      exit 3
   fi

   local queryDestinationFile="${destDir}/${destqueryname}.json"

   # Update name and datasource ID
   echo "   Updating name and data_source_id in ${queryDestinationFile}"
   jq --arg newName "${destqueryname}" --arg dataSourceID "${destinationDatasourceID}" '.name=$newName | .data_source_id=$dataSourceID' ${querySourceFile} >  ${queryDestinationFile}

   # Update env parameter if defined
   echo "   Updating env parameter if defined"
   local envQueryParameter=$(jq -r '.options.parameters[] | select(.name == "env" and .type == "enum")' ${queryDestinationFile})
   if [ -z "${envQueryParameter}" ]
   then
      echo "   env parameter not defined...skipping"
   else
      echo "   env parameter defined...updating to ${envName}"
      jq --arg envName "${envName}" '(.options.parameters[] | select(.name == "env").value) = $envName |  (.options.parameters[] | select(.name == "env").enumOptions) = $envName | (.options.parameters[] | select(.name == "env")."$$value") = $envName' \
       ${queryDestinationFile} > ${queryDestinationFile}.tmp && mv ${queryDestinationFile}.tmp ${queryDestinationFile}
   fi

   # Check if has dependencies
   local dependencyNames=$(jq -r '.options.parameters[] | select(.queryId != null) | .queryId' ${queryDestinationFile})

   if [ -z "$dependencyNames" ]
   then
      echo "   no dependencies defined"
   else
      echo "   Dependencies defined...processing"

      for dependencyName in $dependencyNames
      do
         echo "      processing ${dependencyName}"
         echo "      calling recursive deployment of dev_${dependencyName}"
         deployquery "dev_${dependencyName}"

         local destinationDependencyName="${envName}_${dependencyName}"
         local dependencyURL="${databricksurl}/api/2.0/preview/sql/queries?q=${destinationDependencyName}"
         echo "      fetching id for ${destinationDependencyName}"

         local destinationDependencyID=$(curl -s -H "Authorization: Bearer ${token}" -X GET ${dependencyURL} | jq -r --arg queryname "${destinationDependencyName}" '.results[] | select(.name == $queryname).id')
         if [ -z "${destinationDependencyID}" ]
         then
            echo "      Dependency ${destinationDependencyName} id could not be located ...terminating" >&2
            exit 4
         else
            echo "      Dependency ${destinationDependencyName} id is ${destinationDependencyID}"
            echo "      updating ${queryDestinationFile}"
            jq --arg id "${destinationDependencyID}" --arg name "${dependencyName}" '(.options.parameters[]| select(.queryId == $name).queryId) = $id' ${queryDestinationFile} \
             > ${queryDestinationFile}.tmp && mv ${queryDestinationFile}.tmp ${queryDestinationFile}
         fi

      done
   fi

   # Deploy query
   echo "   Checking if query ${destqueryname} already exists"
   local url="${databricksurl}/api/2.0/preview/sql/queries?q=${destqueryname}"
   local existingID=$(curl -s -H "Authorization: Bearer ${token}" -X GET ${url} | jq -r --arg queryname "${destqueryname}" '.results[] | select(.name == $queryname).id')
   if [ -z "${existingID}" ]
   then
      echo "   deploying new query ${destqueryname}"
      curl -s -H "Authorization: Bearer ${token}" -X POST ${databricksurl}/api/2.0/preview/sql/queries -d @${queryDestinationFile} > ${queryDestinationFile}.result
      local deployedQueryID=$(jq -r '.id' ${queryDestinationFile}.result)
      echo "   query ${destqueryname} deployed with id ${deployedQueryID}"
   else
      echo "   updating existing query ${destqueryname} with id ${existingID}"
      curl -s -H "Authorization: Bearer ${token}" -X POST ${databricksurl}/api/2.0/preview/sql/queries/${existingID} -d @${queryDestinationFile} > ${queryDestinationFile}.result
      local deployedQueryID=$(jq -r '.id' ${queryDestinationFile}.result)
      echo "   query ${destqueryname} updated with id ${deployedQueryID}"
   fi

   #Update permissions
   echo "   updating Query ACL"
   local existingACL=$(curl -s -u "token:${token}" -X GET $databricksurl/api/2.0/preview/sql/permissions/queries/${deployedQueryID} | jq -r '.')
   local newACL=$(echo ${existingACL}| jq -r 'del (.object_id) | del (.object_type) | del (.access_control_list[] | select(.group_name == "admins"))')
   echo ${newACL} | jq -r --argjson adminacl "${adminPermissions}" '.access_control_list += [$adminacl]' > ${queryDestinationFile}.acl
   local objectid=$(curl -s -u "token:${token}" -X POST $databricksurl/api/2.0/preview/sql/permissions/queries/${deployedQueryID} -d @${queryDestinationFile}.acl | jq -r '.object_id')

   if [ "${objectid}" == "null" ]
   then
      echo "... could not update ACL on query ${destqueryname} with ID ${deployedQueryID}" >&2
      exit 5
   else
      echo "   updated ACL for ${objectid}"
   fi
}


########### Main
while getopts c:s:t:u:e: flag
do
    case "${flag}" in
        c) configFile=${OPTARG};;
        s) soruceDir=${OPTARG};;
        t) token=${OPTARG};;
        u) databricksurl=${OPTARG};;
        e) envName=${OPTARG};;
    esac
done

# Datasource ID retreival and validation
destinationDatasourceName=$(jq -r --arg envName "$envName" '.environments[$envName].data_source_name' $configFile)
echo "Destination datasoruce name as ${dataSourceFieldName}=${destinationDatasourceName}"
echo "Validating datasource name ${destinationDatasourceName}"
destinationDatasourceID=$(curl -s -H "Authorization: Bearer ${token}" -X GET ${databricksurl}/api/2.0/preview/sql/data_sources | jq -r --arg name ${destinationDatasourceName} '.[] | select(.name == $name).id')
if [ -z "$destinationDatasourceID" ]
then
   echo "   Datasource with name ${destinationDatasourceName} not found" >&2
   exit 2
else
   echo "Destination datasoruce ID is ${destinationDatasourceID}"
fi

destDir="tmpdst"
rm -rf ${destDir}
mkdir ${destDir}

adminPermissions='{"group_name": "admins","permission_level": "CAN_EDIT"}'

jq -c '.queries[]' $configFile |
while IFS=$"\n" read -r qurydefinition; do
   name=$(echo "$qurydefinition" | jq -r '.name')
   echo "Processing "$name
   deployquery $name
done