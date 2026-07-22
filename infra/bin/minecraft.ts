#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib/core';
import { MinecraftStack } from '../lib/minecraft-stack.js';
import { defaultConfig } from '../config/server-config.js';

const app = new cdk.App();

new MinecraftStack(app, 'MinecraftStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: defaultConfig.region,
  },
  serverConfig: defaultConfig,
});
