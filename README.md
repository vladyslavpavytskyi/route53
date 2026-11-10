# cmtr-g4y25hc6 Route53 Failover CI/CD

## Layout
```
route53/
├── template.yml              # CloudFormation: private zone, health check, failover records
├── buildspec.yml              # CodeBuild: pulls SSM params, deploys the stack
├── codebuild-project.json     # CodeBuild project definition
├── pipeline.json.template     # CodePipeline definition (placeholders filled by setup.sh)
├── setup.sh                   # Runs everything end to end
└── iam/
    ├── codebuild-trust-policy.json
    ├── codebuild-permissions-policy.json
    ├── pipeline-trust-policy.json
    └── pipeline-permissions-policy.json
```

## Prerequisites
- AWS CLI v2 configured with credentials that can create IAM roles, CodeCommit,
  CodeBuild, CodePipeline, S3 and Route 53 resources.
- `git` installed.

## Run
```bash
./setup.sh
```

This will, in order:
1. Create `cmtr-g4y25hc6-repo` and push `template.yml` + `buildspec.yml` to `main`.
2. Create `cmtr-g4y25hc6-codebuild-role` (least privilege — no AdministratorAccess).
3. Create `cmtr-g4y25hc6-pipeline-role` (needed for the pipeline itself).
4. Create an S3 bucket for pipeline artifacts.
5. Create the `cmtr-g4y25hc6-codebuild` CodeBuild project.
6. Create the `cmtr-g4y25hc6-pipeline` CodePipeline (Source: CodeCommit `main`,
   polling enabled so a new commit auto-triggers it → Build: CodeBuild).

CodeBuild's `buildspec.yml` then reads the four SSM parameters
(`zone_name`, `app_name`, `ec2_ip_primary`, `ec2_ip_secondary` — the last
from `ap-south-1`), looks up the primary VPC ID by tag, and runs
`aws cloudformation deploy` to create `cmtr-g4y25hc6-r53-stack`.

## Verifing
```bash
aws codepipeline get-pipeline-state --name cmtr-g4y25hc6-pipeline --region eu-west-1
aws cloudformation describe-stacks --stack-name cmtr-g4y25hc6-r53-stack --region eu-west-1 --query 'Stacks[0].StackStatus'
```

Then, from the SSM Session Manager shell on `cmtr-g4y25hc6-ec2-test`:
```bash
dig +short app.cmtr-g4y25hc6.internal
# Expected: the primary EC2's public IP (ec2_ip_primary)
```
