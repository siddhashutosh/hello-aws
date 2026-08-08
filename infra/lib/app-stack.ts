import * as cdk from 'aws-cdk-lib';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';

export type EnvName = 'dev' | 'test' | 'prod';
export const ENV_NAMES: EnvName[] = ['dev', 'test', 'prod'];

/**
 * Each environment gets its own CDK bootstrap qualifier, so the IAM role that
 * deploys `dev` has no path to the roles that deploy `prod`.
 */
export const qualifierFor = (envName: EnvName) => `h${envName}`;

export interface AppStackProps extends cdk.StackProps {
  envName: EnvName;
  /** Bucket holding build artifacts, shared by all environments. */
  artifactBucket: string;
  /** S3 key of the zip to deploy, e.g. `artifacts/sha-a1b2c3d.zip`. */
  artifactKey: string;
}

export class AppStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: AppStackProps) {
    const { envName, artifactBucket, artifactKey } = props;

    super(scope, id, {
      ...props,
      synthesizer: new cdk.DefaultStackSynthesizer({
        qualifier: qualifierFor(envName),
      }),
    });

    const isProd = envName === 'prod';

    // 25 GB storage + 200M requests/month are Always Free, with no expiry date.
    const table = new dynamodb.Table(this, 'Table', {
      tableName: `hello-${envName}`,
      partitionKey: { name: 'pk', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      // Never let a `cdk destroy` on prod take the data with it.
      removalPolicy: isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: isProd },
    });

    // Declared explicitly so retention is enforced. A Lambda-created log group
    // defaults to "never expire", which quietly accrues CloudWatch storage cost.
    const logGroup = new logs.LogGroup(this, 'ApiLogs', {
      logGroupName: `/aws/lambda/hello-${envName}`,
      retention: isProd ? logs.RetentionDays.ONE_MONTH : logs.RetentionDays.THREE_DAYS,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const fn = new lambda.Function(this, 'Api', {
      functionName: `hello-${envName}`,
      runtime: lambda.Runtime.NODEJS_22_X,
      // ARM is ~20% cheaper per GB-second, so the free 400,000 GB-sec goes further.
      architecture: lambda.Architecture.ARM_64,
      handler: 'index.handler',
      code: lambda.Code.fromBucket(
        s3.Bucket.fromBucketName(this, 'Artifacts', artifactBucket),
        artifactKey,
      ),
      memorySize: isProd ? 512 : 256,
      timeout: cdk.Duration.seconds(10),
      environment: {
        ENV: envName,
        TABLE: table.tableName,
        RELEASE: artifactKey,
      },
      logGroup,
    });

    table.grantReadWriteData(fn);

    // A Function URL is free. API Gateway's 1M requests/month expires after 12
    // months, so it is deliberately not used here.
    const url = fn.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.NONE });

    new cdk.CfnOutput(this, 'Url', {
      value: url.url,
      description: 'Public HTTPS endpoint',
    });

    // The promote workflow reads this to discover what the upstream environment
    // is actually running, so only artifacts that ran there can move forward.
    new cdk.CfnOutput(this, 'ArtifactKey', {
      value: artifactKey,
      description: 'Deployed artifact key',
    });
  }
}
