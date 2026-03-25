#!/usr/bin/env node
'use strict';

const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const readline = require('readline');

const PACKAGE_ROOT = path.resolve(__dirname, '..');
const CONFIG_FILE = '.fixer.json';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function die(msg) {
  console.error(`\x1b[31m[fixer] ${msg}\x1b[0m`);
  process.exit(1);
}

function info(msg) {
  console.log(`\x1b[34m[fixer]\x1b[0m ${msg}`);
}

function ok(msg) {
  console.log(`\x1b[32m[fixer]\x1b[0m ${msg}`);
}

function findConfig() {
  let dir = process.cwd();
  while (true) {
    const candidate = path.join(dir, CONFIG_FILE);
    if (fs.existsSync(candidate)) return candidate;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function loadConfig() {
  const configPath = findConfig();
  if (!configPath) return {};
  try {
    return JSON.parse(fs.readFileSync(configPath, 'utf8'));
  } catch (e) {
    die(`Failed to parse ${configPath}: ${e.message}`);
  }
}

function ask(rl, question, defaultValue) {
  const suffix = defaultValue ? ` (${defaultValue})` : '';
  return new Promise((resolve) => {
    rl.question(`${question}${suffix}: `, (answer) => {
      resolve(answer.trim() || defaultValue || '');
    });
  });
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

async function cmdInit() {
  const existing = findConfig();
  if (existing) {
    info(`Config already exists at ${existing}`);
  }

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

  info('Setting up fixer configuration...\n');

  const repo = await ask(rl, 'Default repository (owner/repo)', '');
  const maxRetries = await ask(rl, 'Max retries per issue', '3');
  const autoMerge = await ask(rl, 'Auto-merge PRs when CI passes (true/false)', 'true');
  const notifyMethod = await ask(rl, 'Notification method (none/slack/ntfy/email)', 'none');

  const config = {
    repo: repo || undefined,
    maxRetries: parseInt(maxRetries, 10),
    autoMerge: autoMerge === 'true',
    notify: notifyMethod,
  };

  if (notifyMethod.includes('slack')) {
    config.slackWebhook = await ask(rl, 'Slack webhook URL', '');
  }
  if (notifyMethod.includes('ntfy')) {
    config.ntfyTopic = await ask(rl, 'ntfy topic', '');
  }
  if (notifyMethod.includes('email')) {
    config.smtpTo = await ask(rl, 'Recipient email', '');
    config.smtpFrom = await ask(rl, 'Sender email', 'fixer@localhost');
  }

  rl.close();

  // Remove undefined keys
  Object.keys(config).forEach((k) => config[k] === undefined && delete config[k]);

  const dest = path.join(process.cwd(), CONFIG_FILE);
  fs.writeFileSync(dest, JSON.stringify(config, null, 2) + '\n');
  ok(`Config written to ${dest}`);
  info('Run `fixer doctor` to verify your setup.');
}

function cmdDoctor() {
  info('Checking dependencies...\n');
  const deps = ['gh', 'claude', 'git', 'jq', 'curl'];
  let allGood = true;

  for (const cmd of deps) {
    try {
      execSync(`command -v ${cmd}`, { stdio: 'pipe' });
      ok(`  ${cmd} — found`);
    } catch {
      console.log(`\x1b[31m[fixer]   ${cmd} — NOT FOUND\x1b[0m`);
      allGood = false;
    }
  }

  console.log('');

  // Check gh auth
  try {
    execSync('gh auth status', { stdio: 'pipe' });
    ok('  gh auth — authenticated');
  } catch {
    console.log('\x1b[33m[fixer]   gh auth — not authenticated (run `gh auth login`)\x1b[0m');
    allGood = false;
  }

  // Check config
  const configPath = findConfig();
  if (configPath) {
    ok(`  config — ${configPath}`);
  } else {
    console.log('\x1b[33m[fixer]   config — none found (run `fixer init`)\x1b[0m');
  }

  console.log('');
  if (allGood) {
    ok('All checks passed. You\'re good to go!');
  } else {
    console.log('\x1b[33m[fixer] Some checks failed. Fix the issues above before running.\x1b[0m');
    process.exit(1);
  }
}

function cmdRun(args) {
  const config = loadConfig();

  // Build env from config (env vars still take precedence via fixer.sh defaults)
  const env = { ...process.env };
  if (config.maxRetries && !env.MAX_RETRIES) env.MAX_RETRIES = String(config.maxRetries);
  if (config.autoMerge !== undefined && !env.AUTO_MERGE) env.AUTO_MERGE = String(config.autoMerge);
  if (config.notify && !env.NOTIFY_METHOD) env.NOTIFY_METHOD = config.notify;
  if (config.slackWebhook && !env.SLACK_WEBHOOK) env.SLACK_WEBHOOK = config.slackWebhook;
  if (config.ntfyTopic && !env.NTFY_TOPIC) env.NTFY_TOPIC = config.ntfyTopic;
  if (config.smtpTo && !env.SMTP_TO) env.SMTP_TO = config.smtpTo;
  if (config.smtpFrom && !env.SMTP_FROM) env.SMTP_FROM = config.smtpFrom;

  // If no repo arg provided, use config default
  let runArgs = args;
  if (runArgs.length === 0 || runArgs[0].startsWith('-')) {
    if (config.repo) {
      runArgs = [config.repo, ...runArgs];
    } else {
      die('No repository specified. Pass owner/repo as argument or set "repo" in .fixer.json');
    }
  }

  const script = path.join(PACKAGE_ROOT, 'fixer.sh');
  const child = spawn('bash', [script, ...runArgs], {
    env,
    stdio: 'inherit',
    cwd: process.cwd(),
  });

  child.on('close', (code) => process.exit(code || 0));
}

function cmdDocker(args) {
  const script = path.join(PACKAGE_ROOT, 'run-container.sh');
  if (!fs.existsSync(script)) {
    die('run-container.sh not found. Docker mode requires the full repo checkout.');
  }
  const child = spawn('bash', [script, ...args], {
    stdio: 'inherit',
    cwd: PACKAGE_ROOT,
  });
  child.on('close', (code) => process.exit(code || 0));
}

// ---------------------------------------------------------------------------
// CLI routing
// ---------------------------------------------------------------------------

function printUsage() {
  console.log(`
Usage: fixer <command> [options]

Commands:
  init            Create a .fixer.json config file interactively
  run <repo> [#]  Run fixer on a repo (or use default from config)
  doctor          Check that all dependencies are installed
  docker <repo>   Run fixer inside a Docker container

Examples:
  fixer init
  fixer run octocat/hello-world
  fixer run octocat/hello-world 42 17
  fixer doctor

Configuration:
  Settings are read from .fixer.json (searched up from cwd).
  Environment variables still work and take precedence over config.
`);
}

const [command, ...rest] = process.argv.slice(2);

switch (command) {
  case 'init':
    cmdInit();
    break;
  case 'run':
    cmdRun(rest);
    break;
  case 'doctor':
    cmdDoctor();
    break;
  case 'docker':
    cmdDocker(rest);
    break;
  case '-h':
  case '--help':
  case 'help':
  case undefined:
    printUsage();
    break;
  default:
    // If first arg looks like owner/repo, treat as implicit `run`
    if (command && command.includes('/') && !command.startsWith('-')) {
      cmdRun([command, ...rest]);
    } else {
      die(`Unknown command: ${command}\nRun 'fixer --help' for usage.`);
    }
    break;
}
