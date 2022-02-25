# Databricks sql queries and jobs CI/CD resources
Scripts and  azdo templates for databricks sql queries and jobs.

This is a very basic toolset for simple scenarios. In the future it will be developed untill a better version is provided by Databricks or the community.

## Repo Overview
Databricks [jobs](https://docs.microsoft.com/en-us/azure/databricks/jobs) and [sql queries](https://docs.microsoft.com/en-us/azure/databricks/scenarios/sql/) are features are not backed by git at this time. Which creates a chalange when there is a need to promote queries and jobs
between DB environments.

This repo contains a few resources that aim to provide a basic ability to create a CI/CD pipeline for those components using databricks API.
Exporting from a source envirnment, committing to git, deploying to target environment.

## Assumptions
1. The jobs in the source DB environment follow the naming standard

            $projectname_$environment_$jobname
2. The Databricks Git repo branch for notebooks in the source environment is develop

3. The sql queries in the source DB environment follow the naming standard of

            $environment_$projectname_$queryname

## CI/CD Process overview
1. A developer develops jobs and queries in the DB UI in the source environment.
2. A developer creates config files with a list of jobs and queries and commits to the repo under jobs and sqlqueries folders respectiveley.
3. The jobs and queries config files are exported and commited to the repo under jobs/src and sqlqueries/src
4. The jobs/queries config files are updated with the target env values(qa name, qa cluster ID etc ) and deployed to the target environment.



### Jobs
### Requirements
(Databrics CLI)[https://docs.databricks.com/dev-tools/cli/index.html] and a configured profile. In the example the profile name is AZDO

### Process
The config file (sample/jobs/jobs_params.json) has a list of environements and jobs for a project.

This file is provided as a parameter to the pulljobs.sh script. The script downloads the job JSON using the API, updates and saves it under jobs/src folder.
```
./pulljobs.sh -c "jobs/jobs_params.json" -p "AZDO"
```

For deployment all the jobs from a folder are deployed, while updating the cluster id (-c), the branch name in (-b) and the environment part of the job name (-e)
```
./deployjobs.sh -c qa-cluster -e qa -b release -s jobs/src - "AZDO"
```

### Queries
The config file (sample/sqlqueries/queries_params.json) has a a list of environements and queries for a project.

Each query definition contains the source query name, and wherever the query schedule will be saved and thus promoted.

Each query uses an env parameter which is used in the queries.

Since queries can depend on one another, the script will recursivly get all of the dependencies for the queries in the list

Pull sql queries from source env
```
./pullsqlqueries.sh -c "sqlqueries/queries_dev_params.json" -t "DATABRICKSTOKEN" -u "https://adb-XXXXXXXXXXXXXXXXXX.XXXXX.azuredatabricks.net"
```

Deploy sql queries to target env
```
./deploysqlqueries.sh -c "sqlqueries/queries_dev_params.json"  -s "sqlqueries/src" -t "DATABRICKSTOKEN" -u "https://adb-XXXXXXXXXXXXXXXXXX.XXXXX.azuredatabricks.net" -e "dev"
```

## Azure devops templates


## Sample Azure devops pipeline
```
# Sample project pipeline
# develop - push git changes to DB, pull jobs and queries to git and commit with [no-ci]
# qa - push git changes to DB, deploy jobs and queries to DB
name: project-$(Build.SourceBranchName)-$(rev:rso)
trigger:
  - develop
  - release
  - production

pr: none

resources:
  repositories:
  - repository: AzurePipelineTemplates
    type: git
    name: OrgName/DevOps
    ref : refs/heads/main

variables:
  - name: isProduction
    value: $[eq(variables['Build.SourceBranch'], 'refs/heads/production')]
  - name: isDevelop
    value: $[eq(variables['Build.SourceBranch'], 'refs/heads/develop')]
  - name: isRelease
    value: $[eq(variables['Build.SourceBranch'], 'refs/heads/release')]
  - name: isManual
    value: $[eq(variables['Build.Reason'], 'Manual')]

pool:
  vmImage: 'ubuntu-latest'

stages:
# ---------------------------------------------------------------------------------------------------------------------
# Dev stage
# ---------------------------------------------------------------------------------------------------------------------
  - stage: dev
    dependsOn: []
    displayName: "Deploy to Dev"
    condition: and(succeeded(), eq(variables.isDevelop, true))
    variables:
      - group: variable-group-dev
    jobs:
      - deployment: repo
        displayName: "pull git repo"
        environment: "project DEV"
        strategy:
              runOnce:
                deploy:
                  steps:
                    - template:  pipeline-templates/databricks-git-pull.yml@AzurePipelineTemplates
                      parameters:
                        dataBricksURL: '$(DatabricksURL}'
                        repoId: '3282692936536291'
                        repoBranch: 'develop'
                        databricks_git_token: '$(databricks-git-token)'

      # Get Databricks Token
      - template: pipeline-templates/getAzureDatabricksTokenJob.yml@AzurePipelineTemplates
        parameters:
          spAppId: '$(ServicePrincipalClientAD)'
          spPassword: '$(ServicePrincipalSecret)'
          ResourceGroupName: 'DatabricksRG'
          DatabricksWorkspaceName: 'DatabricksWorkspaceName'
          SubscriptionId: $(SubscriptionID)
          TenantId: $(TenantID)
          AzureRegion: 'eastus'
          Jobname: 'getdbtoken'

      - job: queries
        dependsOn: [getdbtoken]
        displayName: "Pull databricks sql queries"
        pool:
          vmImage: 'ubuntu-latest'
        variables:
          BearerToken: $[dependencies.getdbtoken.outputs['outputBearerToken.BearerToken']]
        steps:
          - checkout: self
            path: self
            persistCredentials: true

          - template: pipeline-templates/pullDatabricksSqlQueries.yml@AzurePipelineTemplates
            parameters:
              databricksToken: $(BearerToken)
              dataBricksURL: '$(DatabricksURL}'
              queriesConfigFilePath: 'sqlqueries/queries_params.json'


      - job: jobs
        dependsOn: [getdbtoken]
        displayName: "Pull databricks jobs"
        pool:
          vmImage: 'ubuntu-latest'
        variables:
          BearerToken: $[dependencies.getdbtoken.outputs['outputBearerToken.BearerToken']]
        steps:
          - checkout: self
            path: self
            persistCredentials: true

          - template: pipeline-templates/pullDatabricksJobs.yml@AzurePipelineTemplates
            parameters:
              databricksToken: $(BearerToken)
              dataBricksURL: '$(DatabricksURL}'
              jobsConfigFilePath: 'jobs/jobs_params.json'

# ---------------------------------------------------------------------------------------------------------------------
# QA stage
# ---------------------------------------------------------------------------------------------------------------------
  - stage: qa
    dependsOn: []
    displayName: "Deploy to QA"
    condition: and(succeeded(), eq(variables.isRelease, true))
    variables:
      - group: variable-group-qa
    jobs:
      - deployment: repo
        displayName: "pull git repo"
        environment: "project QA"
        strategy:
              runOnce:
                deploy:
                  steps:
                    - template:  pipeline-templates/databricks-git-pull.yml@AzurePipelineTemplates
                      parameters:
                        dataBricksURL: '$(DatabricksURL}'
                        repoId: '3282692936536294'
                        repoBranch: 'release'
                        databricks_git_token: '$(databricks-git-token)'

      # Get Databricks Token
      - template: pipeline-templates/getAzureDatabricksTokenJob.yml@AzurePipelineTemplates
        parameters:
          spAppId: '$(ServicePrincipalClientAD)'
          spPassword: '$(ServicePrincipalSecret)'
          ResourceGroupName: 'DatabricksRG'
          DatabricksWorkspaceName: 'DatabricksWorkspaceName'
          SubscriptionId: $(SubscriptionID)
          TenantId: $(TenantID)
          AzureRegion: 'eastus'
          Jobname: 'getdbtoken'

      - deployment: queries
        condition: and(succeeded(), eq(variables.isManual, true))
        dependsOn: [getdbtoken]
        displayName: "Deploy queries"
        environment: "project QA"
        variables:
          BearerToken: $[dependencies.getdbtoken.outputs['outputBearerToken.BearerToken']]
        strategy:
              runOnce:
                deploy:
                  steps:
                    - checkout: self
                      path: self
                      persistCredentials: true

                    - template: pipeline-templates/deployDatabricksSqlQueries.yml@AzurePipelineTemplates
                      parameters:
                        databricksToken: $(BearerToken)
                        dataBricksURL: '$(DatabricksURL}'
                        queriesConfigFilePath: 'sqlqueries/queries_params.json'
                        queriesFilesPath: 'sqlqueries/src'
                        envName: 'qa'

      - deployment: jobs
        condition: and(succeeded(), eq(variables.isManual, true))
        dependsOn: [getdbtoken, repo]
        displayName: "Deploy jobs"
        environment: "project QA"
        variables:
          BearerToken: $[dependencies.getdbtoken.outputs['outputBearerToken.BearerToken']]
        strategy:
              runOnce:
                deploy:
                  steps:
                    - checkout: self
                      path: self

                    - template: pipeline-templates/deployDatabricksJobs.yml@AzurePipelineTemplates
                      parameters:
                        databricksToken: $(BearerToken)
                        dataBricksURL: '$(DatabricksURL}'
                        dataBricksClusterName: 'qa-cluster'
                        envName: 'qa'
                        jobsDirPath: 'jobs/src'
                        branchName: 'release'

```

## Limitations
The scripts assume following a certain naming format
The sql/job scripts will fail if there are multiple jobs/queries with the same name.
The jobs are assumed to use the same cluster for all jobs/taks/sub-tasks in the target environment
The sql queries are assumed to use the same data source for all queries in the target environment.

## Contributing
Make a PR to this repo or fork it and make a better one! Any contributions are welcome.
