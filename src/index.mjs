import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, UpdateCommand } from '@aws-sdk/lib-dynamodb';

// The Node.js 22 managed Lambda runtime ships AWS SDK v3, so these imports resolve
// at runtime without being bundled. That keeps the deployment zip at a few KB.
// Trade-off: you inherit whatever SDK version AWS ships. Bundle it if you ever need
// to pin a version.

const ENV = process.env.ENV ?? 'local';
const TABLE = process.env.TABLE ?? '';
const RELEASE = process.env.RELEASE ?? 'unknown';

// Created once per container, reused across warm invocations.
const ddb = TABLE ? DynamoDBDocumentClient.from(new DynamoDBClient({})) : null;

/** Atomically increment the visit counter and return the new total. */
async function countVisit() {
  if (!ddb) return null;
  const out = await ddb.send(
    new UpdateCommand({
      TableName: TABLE,
      Key: { pk: 'counter#visits' },
      UpdateExpression: 'ADD #n :one',
      ExpressionAttributeNames: { '#n': 'count' },
      ExpressionAttributeValues: { ':one': 1 },
      ReturnValues: 'UPDATED_NEW',
    }),
  );
  return out.Attributes?.count ?? null;
}

export function json(statusCode, body) {
  return {
    statusCode,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
    body: `${JSON.stringify(body, null, 2)}\n`,
  };
}

/** Lambda Function URLs deliver the API Gateway v2 payload shape. */
export function pathOf(event) {
  return event?.requestContext?.http?.path ?? event?.rawPath ?? '/';
}

export const handler = async (event) => {
  const path = pathOf(event);

  if (path === '/health') {
    return json(200, { status: 'ok', env: ENV, release: RELEASE });
  }

  if (path === '/') {
    let visits = null;
    let dbError;
    try {
      visits = await countVisit();
    } catch (err) {
      // A broken table must not take the whole endpoint down — report and carry on.
      dbError = err?.name ?? 'DynamoDBError';
    }

    return json(200, {
      message: 'Hello, world 2!',
      env: ENV,
      release: RELEASE,
      visits,
      ...(dbError ? { dbError } : {}),
      time: new Date().toISOString(),
    });
  }

  return json(404, { error: 'not found', path });
};
