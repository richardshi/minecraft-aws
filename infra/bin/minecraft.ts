#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib/core';
import { MinecraftStack } from '../lib/minecraft-stack.js';
import { defaultConfig, resolveConfigFromEnv } from '../config/server-config.js';

const app = new cdk.App();
const deployConfig = resolveConfigFromEnv(defaultConfig);

new MinecraftStack(app, 'MinecraftStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: deployConfig.region,
  },
  serverConfig: deployConfig,
});
