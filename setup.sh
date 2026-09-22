#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# cmtr-g4y25hc6 Route53 failover CI/CD setup
# Run this from the directory that contains: template.yml, buildspec.yml,
# codebuild-project.json, pipeline.json.template, iam/
# ---------------------------------------------------------------------------

PRIMARY_REGION="eu-west-1"
SECONDARY_REGION="ap-south-1"
REPO_NAME="cmtr-g4y25hc6-repo"
CODEBUILD_ROLE_NAME="cmtr-g4y25hc6-codebuild-role"
PIPELINE_ROLE_NAME="cmtr-g4y25hc6-pipeline-role"
CODEBUILD_PROJECT="cmtr-g4y25hc6-codebuild"
PIPELINE_NAME="cmtr-g4y25hc6-pipeline"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ARTIFACT_BUCKET="cmtr-g4y25hc6-pipeline-artifacts-${ACCOUNT_ID}"

echo "== Account: $ACCOUNT_ID | Primary region: $PRIMARY_REGION =="

# ---------------------------------------------------------------------------
# 1. CodeCommit repository
# ---------------------------------------------------------------------------
echo "== Creating CodeCommit repository =="
aws codecommit create-repository \
  --repository-name "$REPO_NAME" \
  --region "$PRIMARY_REGION" || echo "Repository may already exist, continuing..."

CLONE_URL="https://git-codecommit.${PRIMARY_REGION}.amazonaws.com/v1/repos/${REPO_NAME}"

git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true

rm -rf /tmp/${REPO_NAME}
git clone "$CLONE_URL" /tmp/${REPO_NAME}
cp template.yml buildspec.yml /tmp/${REPO_NAME}/
cd /tmp/${REPO_NAME}
git add template.yml buildspec.yml
git -c user.email="ci@cmtr-g4y25hc6.local" -c user.name="cmtr-g4y25hc6" \
  commit -m "Add Route53 failover template and buildspec" || echo "Nothing to commit"
git branch -M main
git push -u origin main
cd - >/dev/null

# ---------------------------------------------------------------------------
# 2. IAM role for CodeBuild
# ---------------------------------------------------------------------------
echo "== Creating CodeBuild IAM role =="
aws iam create-role \
  --role-name "$CODEBUILD_ROLE_NAME" \
  --assume-role-policy-document file://iam/codebuild-trust-policy.json \
  --region "$PRIMARY_REGION" || echo "Role may already exist, continuing..."

aws iam put-role-policy \
  --role-name "$CODEBUILD_ROLE_NAME" \
  --policy-name "cmtr-g4y25hc6-codebuild-policy" \
  --policy-document file://iam/codebuild-permissions-policy.json

CODEBUILD_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CODEBUILD_ROLE_NAME}"

# ---------------------------------------------------------------------------
# 3. IAM role for CodePipeline
# ---------------------------------------------------------------------------
echo "== Creating CodePipeline IAM role =="
aws iam create-role \
  --role-name "$PIPELINE_ROLE_NAME" \
  --assume-role-policy-document file://iam/pipeline-trust-policy.json \
  --region "$PRIMARY_REGION" || echo "Role may already exist, continuing..."

aws iam put-role-policy \
  --role-name "$PIPELINE_ROLE_NAME" \
  --policy-name "cmtr-g4y25hc6-pipeline-policy" \
  --policy-document file://iam/pipeline-permissions-policy.json

PIPELINE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${PIPELINE_ROLE_NAME}"

echo "Waiting for IAM roles to propagate..."
sleep 12

# ---------------------------------------------------------------------------
# 4. S3 bucket for pipeline artifacts
# ---------------------------------------------------------------------------
echo "== Creating pipeline artifact bucket =="
if [ "$PRIMARY_REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$ARTIFACT_BUCKET" --region "$PRIMARY_REGION" || true
else
  aws s3api create-bucket --bucket "$ARTIFACT_BUCKET" --region "$PRIMARY_REGION" \
    --create-bucket-configuration LocationConstraint="$PRIMARY_REGION" || true
fi
aws s3api put-bucket-versioning --bucket "$ARTIFACT_BUCKET" \
  --versioning-configuration Status=Enabled

# ---------------------------------------------------------------------------
# 5. CodeBuild project
# ---------------------------------------------------------------------------
echo "== Creating CodeBuild project =="
aws codebuild create-project \
  --cli-input-json file://codebuild-project.json \
  --service-role "$CODEBUILD_ROLE_ARN" \
  --region "$PRIMARY_REGION" \
  || aws codebuild update-project \
       --cli-input-json file://codebuild-project.json \
       --service-role "$CODEBUILD_ROLE_ARN" \
       --region "$PRIMARY_REGION"

# ---------------------------------------------------------------------------
# 6. CodePipeline
# ---------------------------------------------------------------------------
echo "== Creating CodePipeline =="
sed -e "s#PIPELINE_ROLE_ARN#${PIPELINE_ROLE_ARN}#" \
    -e "s#ARTIFACT_BUCKET#${ARTIFACT_BUCKET}#" \
    pipeline.json.template > pipeline.json

aws codepipeline create-pipeline \
  --cli-input-json file://pipeline.json \
  --region "$PRIMARY_REGION" \
  || echo "Pipeline may already exist — edit manually with 'aws codepipeline update-pipeline' if needed."

echo "== Done. Watch the pipeline: =="
echo "aws codepipeline get-pipeline-state --name $PIPELINE_NAME --region $PRIMARY_REGION"
echo "aws cloudformation describe-stacks --stack-name cmtr-g4y25hc6-r53-stack --region $PRIMARY_REGION --query 'Stacks[0].StackStatus'"
