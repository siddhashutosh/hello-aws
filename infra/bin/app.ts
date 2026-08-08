#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { AppStack, ENV_NAMES, EnvName } from '../lib/app-stack';

const app = new cdk.App();

const envName = app.node.tryGetContext('envName') as EnvName | undefined;
const artifactKey = app.node.tryGetContext('artifactKey') as string | undefined;
const artifactBucket =
  (app.node.tryGetContext('artifactBucket') as string | undefined) ??
  process.env.ARTIFACT_BUCKET;

if (!envName || !ENV_NAMES.includes(envName)) {
  throw new Error(
    `Missing or invalid --context envName. Expected one of: ${ENV_NAMES.join(', ')}`,
  );
}
if (!artifactKey) {
  throw new Error(
    'Missing --context artifactKey (e.g. artifacts/sha-a1b2c3d.zip). ' +
      'Deploys are artifact-driven so the same build can be promoted across environments.',
  );
}
if (!artifactBucket) {
  throw new Error('Missing artifactBucket. Set it in cdk.json context or $ARTIFACT_BUCKET.');
}

new AppStack(app, `Hello-${envName}`, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION ?? 'ap-south-1',
  },
  envName,
  artifactBucket,
  artifactKey,
  tags: {
    Project: 'hello-aws',
    Environment: envName,
    ManagedBy: 'cdk',
  },
});
