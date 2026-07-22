# Welcome to your CDK TypeScript project

This is a blank project for CDK development with TypeScript.

The `cdk.json` file tells the CDK Toolkit how to execute your app.

## Useful commands

* `npm run build`   type-check the project
* `npm run watch`   watch for changes and type-check
* `npm run test`    perform the jest unit tests
* `npm run test:shell`   run the bats backup/restore tests
* `npm run predeploy`    run all local pre-deploy checks
* `npm run deploy:all`   run checks, prepare/review/execute a deploy change set, and print outputs
* `npx cdk deploy`  deploy this stack to your default AWS account/region
* `npx cdk diff`    compare deployed stack with current state
* `npx cdk synth`   emits the synthesized CloudFormation template

## Combined Deploy Script

Use the wrapper script when you want the AWS deploy workflow in one command:

```bash
npm run deploy:all
```

By default it runs:

```bash
npm run predeploy
aws sts get-caller-identity --profile minecraft-prod
AWS_REGION=us-west-2 AWS_DEFAULT_REGION=us-west-2 CDK_DEPLOY_REGION=us-west-2 CDK_MINECRAFT_EULA_ACCEPTED=true npx cdk diff MinecraftStack --profile minecraft-prod --method=change-set
AWS_REGION=us-west-2 AWS_DEFAULT_REGION=us-west-2 CDK_DEPLOY_REGION=us-west-2 CDK_MINECRAFT_EULA_ACCEPTED=true npx cdk deploy MinecraftStack --profile minecraft-prod --method=prepare-change-set --change-set-name minecraft-deploy-<timestamp>
aws cloudformation describe-change-set --stack-name MinecraftStack --change-set-name minecraft-deploy-<timestamp> --profile minecraft-prod --region us-west-2
AWS_REGION=us-west-2 AWS_DEFAULT_REGION=us-west-2 CDK_DEPLOY_REGION=us-west-2 CDK_MINECRAFT_EULA_ACCEPTED=true npx cdk deploy MinecraftStack --profile minecraft-prod --method=execute-change-set --change-set-name minecraft-deploy-<timestamp> --outputs-file minecraft-outputs.json
aws cloudformation describe-stacks --stack-name MinecraftStack --profile minecraft-prod --region us-west-2 --query 'Stacks[0].{Status:StackStatus,TerminationProtection:EnableTerminationProtection,Outputs:Outputs}' --output json
```

The repository default for `minecraftEulaAccepted` stays `false` so tests can enforce that it is never committed enabled. The deploy flow opts in at runtime via `CDK_MINECRAFT_EULA_ACCEPTED=true`.

You can override the defaults:

```bash
npm run deploy:all -- --profile minecraft-prod --region us-west-2 --change-set-name minecraft-deploy-manual --yes
```

Useful options:

* `npm run deploy:all -- --stack MinecraftStack` targets a specific stack
* `npm run deploy:all -- --account-id 574246332047` changes the AWS account guard
* `npm run deploy:all -- --outputs-file minecraft-outputs.json` changes the outputs file path
* `npm run deploy:all -- --skip-checks` skips `npm run predeploy`
* `npm run deploy:all -- --skip-diff` skips `cdk diff`
* `npm run deploy:all -- --yes` executes the prepared change set without prompting

If the prepared change set contains no infrastructure changes, the script exits successfully after deleting the no-op change set.
