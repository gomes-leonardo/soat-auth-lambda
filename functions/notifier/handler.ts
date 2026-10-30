import { PublishCommand, SNSClient } from '@aws-sdk/client-sns';
import { HttpEvent, HttpResult, json, log } from '../shared/http';
import { readParameter } from '../shared/ssm';
import { createNotifier } from './notifier';

const sns = new SNSClient({});

const notifier = createNotifier({
  environment: process.env.ENVIRONMENT ?? 'desconhecido',
  webhookSecret: () => readParameter(requiredEnv('WEBHOOK_SECRET_PARAM')),
  publish: async (subject, message) => {
    await sns.send(
      new PublishCommand({
        TopicArn: requiredEnv('ALERT_TOPIC_ARN'),
        Subject: subject,
        Message: message,
      }),
    );
  },
});

export async function handler(event: HttpEvent): Promise<HttpResult> {
  try {
    return await notifier(event);
  } catch (err) {
    log('error', 'notifier failed', { err: String(err) });
    return json(500, { error: 'internal_error' });
  }
}

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Variavel ${name} nao configurada`);
  return value;
}
