#/bin/bash
#set -o xtrace
function getqueryfile ()
{
   local sourcequeryname=$1
   local destqueryname=$(echo $sourcequeryname | cut -f 2- -d '_')
   local promoteschedule=$2

   echo "   Pulling config for "$sourcequeryname
   local url="${databricksurl}/api/2.0/preview/sql/queries?q=${sourcequeryname}"
   curl -s -H "Authorization: Bearer $token" -X GET $url | jq --arg sourcequeryname "$sourcequeryname" '.results[] | select(.name == $sourcequeryname)' > ${sourcequeryname}.json

   if [ -s ${sourcequeryname}.json ]; then
      echo "   Pulled config for ${sourcequeryname}"
   else
      echo "   Could not pull config for ${sourcequeryname}"
      echo "   Check that the ${sourcequeryname} is shared and name is valid"
      echo "Failed pulling config for ${sourcequeryname}" >&2
      exit 2
   fi

   echo "   Processing schedule"
   if [ "$promoteschedule" == "true" ]
   then
      local schedule=$(jq -r .schedule  ${sourcequeryname}.json)
   else
      local schedule="null"
   fi

   echo "   Processing datasource"
   local data_source_id="TBD"

   echo "   Processing query"
   local query=$(jq -r .query  ${sourcequeryname}.json)

   echo "   Processing tags"
   local tags=$(jq -r .tags  ${sourcequeryname}.json)

   echo "   Processing description"
   local description=$(jq -r .description  ${sourcequeryname}.json)

   echo "   Processing options"
   local sourceoptions=$(jq -r '.options | del(.parameters[].parentQueryId)' ${sourcequeryname}.json)
   local dependencyids=$(jq -r '.options.parameters[] | select(.queryId != null) | .queryId' ${sourcequeryname}.json)

   if [ -z "$dependencyids" ]
   then
      echo "   no dependencies defined"
      local options=$sourceoptions
   else
      echo "   Dependencies defined in source query"
      local options=$sourceoptions

      #Pull implicit dependencies if exist
      for dependencyid in $dependencyids
      do
         echo "      Processing dependency $dependencyid"
         local dependencyName=$(curl -s -H "Authorization: Bearer $token" -X GET ${databricksurl}/api/2.0/preview/sql/queries/$dependencyid | jq -r '.name')
         echo "      Dependency name is $dependencyName"
         local explicit=$(jq -r --arg dependencyName "$dependencyName" '.queries[] | select(.name == $dependencyName) | .name ' $configFile)
         if [ -z "$explicit" ]
         then
            echo "      Not found in config file list...retreiving"
            getqueryfile $dependencyName false
         else
            echo "      Found in config file...skipping"
         fi
      done

      # Update parameters
      local sourceparameters=$(echo $sourceoptions | jq -r '.parameters')
      echo "   Processing parameters"
      echo "[]" >  ${destqueryname}.parameters.json
      echo $sourceparameters |  jq -c '.[]' |
      while IFS=$"\n" read -r parameterdefinition; do
         local parametername=$(echo $parameterdefinition| jq -r '.name')
         echo "      Processing parameter " $parametername
         local queryId=$(echo $parameterdefinition| jq -r '.queryId')
         if [  "$queryId" == "null" ]
         then
            echo "         Simple parameter"
            jq --argjson parameterdefinition "$parameterdefinition" '. += [$parameterdefinition]' ${destqueryname}.parameters.json > ${destqueryname}.parameters.json.tmp && mv ${destqueryname}.parameters.json.tmp ${destqueryname}.parameters.json
         else
            echo "         Dependency"
            local queryId=$(echo $parameterdefinition | jq -r '.queryId')
            echo "         Getting query name for " $queryId
            local queryName=$(curl -s -H "Authorization: Bearer $token" -X GET ${databricksurl}/api/2.0/preview/sql/queries/${queryId}| jq -r '.name')
            local queryName=$(echo $queryName | cut -f 2- -d '_')
            echo "         Updating queryName" $queryName
            local newparam=$(echo $parameterdefinition | jq -r --arg queryName "$queryName" '.value = [] | ."$$value" = [] | .queryId = $queryName ')
            echo "         Adding updated parameter to the file"
            jq --argjson newparam "$newparam" '. += [$newparam]' ${destqueryname}.parameters.json > ${destqueryname}.parameters.json.tmp && mv ${destqueryname}.parameters.json.tmp ${destqueryname}.parameters.json
         fi
      done

      #Update options variable with parameters
      local destparameters=$(jq -r '.' ${destqueryname}.parameters.json)
      local options=$(echo $options | jq -r --argjson destparameters "$destparameters" '.parameters = $destparameters' )
   fi

   echo "   Creating output file for " $destqueryname
   echo {} | jq --arg name "$destqueryname" --arg query "$query" --arg data_source_id "$data_source_id" --arg description "$description" --argjson options "$options" --argjson schedule "$schedule" --argjson tags "$tags" '. + {name: $name} + {query: $query} + {description: $description}+ {data_source_id: $data_source_id} + {schedule: $schedule} + {tags: $tags} + {options: $options}'  > $destqueryname.output.json
   echo "   Moving queryfile"
   mv $destqueryname.output.json sqlqueries/src/$destqueryname.json
}

########### Main
while getopts c:t:u: flag
do
    case "${flag}" in
        c) configFile=${OPTARG};;
        t) token=${OPTARG};;
        u) databricksurl=${OPTARG};;
    esac
done

rm -rf sqlqueries/src
rm -rf *.json
mkdir sqlqueries/src

#echo "Pulling queries"
#curl -s -H "Authorization: Bearer $token" -X GET ${databricksurl}/api/2.0/preview/sql/queries?page_size=250 > queries.json

jq -c '.queries[]' $configFile |
while IFS=$"\n" read -r qurydefinition; do
   name=$(echo "$qurydefinition" | jq -r '.name')
   schedule=$(echo "$qurydefinition" | jq -r '.schedule')
   echo "Processing "$name
   getqueryfile $name $schedule
done

rm -rf *.json