<#
.SYNOPSIS
  One-time AWS setup for hello-aws. Idempotent - safe to re-run.

.DESCRIPTION
  Creates:
    * an S3 bucket for build artifacts (private, versioned, 90-day expiry)
    * the GitHub Actions OIDC identity provider, so no AWS keys are ever
      stored in GitHub
    * a separate CDK bootstrap per environment, each with its own qualifier,
      so the role that deploys dev has no path to the roles that deploy prod
    * one IAM role per environment, trusted only by that GitHub Environment

  Everything it creates is free.

  NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 files as
  ANSI unless they carry a BOM, so non-ASCII characters break the parser.

.EXAMPLE
  aws login
  .\scripts\bootstrap-aws.ps1 -Repo "siddhashutosh/hello-aws"
#>
[CmdletBinding()]
param(
  [string]$Region = 'ap-south-1',
  [string]$Repo   = 'siddhashutosh/hello-aws',
  [string]$Bucket = ''
)

$ProgressPreference = 'SilentlyContinue'
$aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
if (-not (Test-Path $aws)) { $aws = 'aws' }

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Skip($msg) { Write-Host "    $msg (already exists)" -ForegroundColor DarkGray }

function Write-Json($path, $text) {
  # PS 5.1 Set-Content -Encoding utf8 emits a BOM, which the AWS CLI rejects.
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------------ identity ---
Step 'Checking AWS credentials'
$identity = & $aws sts get-caller-identity --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $identity) { Fail "Not signed in. Run 'aws login' first." }
$Account = $identity.Account
Ok "account $Account  ($($identity.Arn))"

# Deliberately does NOT embed the account ID - this name also lives in
# infra/cdk.json, which is committed. Keep the two in sync if you change it.
if (-not $Bucket) { $Bucket = 'hello-aws-artifacts-8f3c2a1d' }

$envs = @(
  @{ Name = 'dev';  Qualifier = 'hdev'  },
  @{ Name = 'test'; Qualifier = 'htest' },
  @{ Name = 'prod'; Qualifier = 'hprod' }
)

# ----------------------------------------------------------- artifact bucket ---
Step "Artifact bucket s3://$Bucket"
& $aws s3api head-bucket --bucket $Bucket 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  & $aws s3api create-bucket --bucket $Bucket --region $Region --create-bucket-configuration "LocationConstraint=$Region" | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "Could not create bucket $Bucket (the name may be taken globally - pass -Bucket)" }
  Ok 'created'
} else {
  Skip 'bucket'
}

& $aws s3api put-public-access-block --bucket $Bucket --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' | Out-Null
& $aws s3api put-bucket-versioning --bucket $Bucket --versioning-configuration 'Status=Enabled' | Out-Null

$lifecycle = '{"Rules":[{"ID":"expire-old-artifacts","Status":"Enabled","Filter":{"Prefix":"artifacts/"},"Expiration":{"Days":90},"NoncurrentVersionExpiration":{"NoncurrentDays":30},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}'
$lcFile = Join-Path $env:TEMP 'hello-aws-lifecycle.json'
Write-Json $lcFile $lifecycle
& $aws s3api put-bucket-lifecycle-configuration --bucket $Bucket --lifecycle-configuration "file://$lcFile" | Out-Null
Ok 'private, versioned, artifacts expire after 90 days'

# ---------------------------------------------------------------------- OIDC ---
Step 'GitHub Actions OIDC provider'
$oidcArn = "arn:aws:iam::${Account}:oidc-provider/token.actions.githubusercontent.com"
$providers = & $aws iam list-open-id-connect-providers --output json | ConvertFrom-Json
if ($providers.OpenIDConnectProviderList.Arn -contains $oidcArn) {
  Skip 'provider'
} else {
  & $aws iam create-open-id-connect-provider --url 'https://token.actions.githubusercontent.com' --client-id-list 'sts.amazonaws.com' | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail 'Could not create the OIDC provider' }
  Ok 'created'
}

# ------------------------------------------------- per-environment bootstrap ---
$infra = Join-Path $PSScriptRoot '..\infra'
Push-Location $infra
try {
  foreach ($e in $envs) {
    $name = $e.Name
    $q    = $e.Qualifier
    Step "CDK bootstrap for '$name' (qualifier $q)"
    # bootstrap still loads the CDK app, and bin/app.ts requires both context
    # values, so pass placeholders. They do not affect the toolkit stack.
    & npx cdk bootstrap "aws://$Account/$Region" --qualifier $q --toolkit-stack-name "CDKToolkit-$name" --cloudformation-execution-policies 'arn:aws:iam::aws:policy/AdministratorAccess' --context envName=$name --context artifactKey=bootstrap-placeholder
    if ($LASTEXITCODE -ne 0) { Fail "cdk bootstrap failed for $name" }
    Ok "CDKToolkit-$name ready"
  }
} finally { Pop-Location }

# ------------------------------------------------------------- deploy roles ---
# GitHub is migrating OIDC tokens to an *immutable* subject claim that embeds
# numeric owner and repo IDs, so a deleted repo name cannot be re-registered to
# steal a role:
#   repo:<owner>@<ownerId>/<repo>@<repoId>:environment:<env>
# The documented name-only form is still issued by some repos, so the trust
# policy below accepts either. Look up the IDs with gh if it is available.
$ownerName, $repoShort = $Repo.Split('/')
$ownerId = ''
$repoId  = ''
if (Get-Command gh -ErrorAction SilentlyContinue) {
  $ownerId = (& gh api "repos/$Repo" --jq '.owner.id' 2>$null)
  $repoId  = (& gh api "repos/$Repo" --jq '.id'       2>$null)
}
if ($ownerId -and $repoId) {
  Step "GitHub IDs resolved: owner=$ownerId repo=$repoId"
} else {
  Write-Host "    WARNING: could not resolve GitHub numeric IDs (is gh installed and logged in?)." -ForegroundColor Yellow
  Write-Host "    Trust policies will only accept the legacy subject form." -ForegroundColor Yellow
}

foreach ($e in $envs) {
  $name = $e.Name
  $q    = $e.Qualifier
  $roleName = "gha-hello-aws-$name"

  Step "IAM role $roleName"

  # Trusted ONLY by this repo's "$name" GitHub Environment. A workflow running
  # against dev cannot assume the prod role - the sub claim would not match.
  # StringEquals against a list means "any one of these", not "all of them".
  $subs = @("repo:${Repo}:environment:${name}")
  if ($ownerId -and $repoId) {
    $subs += "repo:${ownerName}@${ownerId}/${repoShort}@${repoId}:environment:${name}"
  }
  $subsJson = '["' + ($subs -join '","') + '"]'

  $trust = '{"Version":"2012-10-17","Statement":[{' +
    '"Effect":"Allow",' +
    '"Principal":{"Federated":"' + $oidcArn + '"},' +
    '"Action":"sts:AssumeRoleWithWebIdentity",' +
    '"Condition":{"StringEquals":{' +
      '"token.actions.githubusercontent.com:aud":"sts.amazonaws.com",' +
      '"token.actions.githubusercontent.com:sub":' + $subsJson +
    '}}}]}'

  # Only dev may publish artifacts; test and prod deploy existing ones only.
  $publish = ''
  if ($name -eq 'dev') {
    $publish = ',{"Sid":"PublishArtifacts","Effect":"Allow","Action":["s3:PutObject"],' +
               '"Resource":"arn:aws:s3:::' + $Bucket + '/artifacts/*"}'
  }

  $policy = '{"Version":"2012-10-17","Statement":[' +
    '{"Sid":"AssumeThisEnvsCdkRoles","Effect":"Allow","Action":"sts:AssumeRole",' +
      '"Resource":"arn:aws:iam::' + $Account + ':role/cdk-' + $q + '-*-' + $Account + '-' + $Region + '"},' +
    '{"Sid":"ReadBootstrapVersion","Effect":"Allow","Action":"ssm:GetParameter",' +
      '"Resource":"arn:aws:ssm:' + $Region + ':' + $Account + ':parameter/cdk-bootstrap/' + $q + '/version"},' +
    '{"Sid":"ReadOwnStackOutputs","Effect":"Allow","Action":"cloudformation:DescribeStacks",' +
      '"Resource":["arn:aws:cloudformation:' + $Region + ':' + $Account + ':stack/Hello-' + $name + '/*",' +
                  '"arn:aws:cloudformation:' + $Region + ':' + $Account + ':stack/CDKToolkit-' + $name + '/*"]}' +
    $publish + ']}'

  $trustFile  = Join-Path $env:TEMP "hello-aws-trust-$name.json"
  $policyFile = Join-Path $env:TEMP "hello-aws-policy-$name.json"
  Write-Json $trustFile  $trust
  Write-Json $policyFile $policy

  & $aws iam get-role --role-name $roleName 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    & $aws iam create-role --role-name $roleName --assume-role-policy-document "file://$trustFile" --description "GitHub Actions deploy role for hello-aws $name" | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "Could not create role $roleName" }
    Ok 'created'
  } else {
    & $aws iam update-assume-role-policy --role-name $roleName --policy-document "file://$trustFile" | Out-Null
    Skip 'role - trust policy refreshed'
  }

  & $aws iam put-role-policy --role-name $roleName --policy-name 'deploy' --policy-document "file://$policyFile" | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "Could not attach policy to $roleName" }
  Ok 'permissions attached'

  Remove-Item $trustFile, $policyFile -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------------- done ---
Write-Host ""
Write-Host '================================================================' -ForegroundColor Yellow
Write-Host ' Done. Now configure GitHub -> Settings -> Environments' -ForegroundColor Yellow
Write-Host '================================================================' -ForegroundColor Yellow
Write-Host ''
Write-Host "Create environments 'dev', 'test' and 'prod'."
Write-Host "Tick 'Required reviewers' (yourself) on test and prod ONLY."
Write-Host ''
Write-Host 'Then add these as environment VARIABLES (not secrets):'
Write-Host ''
foreach ($e in $envs) {
  Write-Host ("  [{0}]" -f $e.Name) -ForegroundColor Cyan
  Write-Host ("    AWS_ROLE_ARN    = arn:aws:iam::{0}:role/gha-hello-aws-{1}" -f $Account, $e.Name)
  Write-Host ("    AWS_REGION      = {0}" -f $Region)
  if ($e.Name -eq 'dev') { Write-Host ("    ARTIFACT_BUCKET = {0}" -f $Bucket) }
  Write-Host ''
}
Write-Host "Confirm infra/cdk.json has:  artifactBucket = $Bucket"
Write-Host ''
Write-Host 'Finally, set a billing alarm:'
Write-Host '  Billing -> Budgets -> Create budget -> Cost budget -> $1/month -> email alert'
Write-Host ''
