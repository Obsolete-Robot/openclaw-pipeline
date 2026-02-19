#!/usr/bin/env node
/**
 * Create a post in a Discord forum channel.
 * 
 * Usage:
 *   DISCORD_BOT_TOKEN=... node create-post.mjs <channel_id> --name "Post Title" --content "Post content"
 * 
 * Options:
 *   --name     Post/thread title (required)
 *   --content  Post content (required)
 *   --tag      Tag ID to apply (optional, can specify multiple)
 */

const args = process.argv.slice(2);
const CHANNEL_ID = args[0];

if (!CHANNEL_ID || CHANNEL_ID.startsWith('--')) {
  console.error('Usage: node create-post.mjs <channel_id> --name "Title" --content "Content" [--tag <id>]');
  process.exit(1);
}

const token = process.env.DISCORD_BOT_TOKEN;
if (!token) {
  console.error('Error: DISCORD_BOT_TOKEN environment variable not set');
  process.exit(1);
}

// Parse arguments
function getArg(name) {
  const idx = args.indexOf(`--${name}`);
  return idx !== -1 && args[idx + 1] ? args[idx + 1] : null;
}

function getAllArgs(name) {
  const results = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === `--${name}` && args[i + 1]) {
      results.push(args[i + 1]);
    }
  }
  return results;
}

const name = getArg('name');
const content = getArg('content');
const tags = getAllArgs('tag');

if (!name || !content) {
  console.error('Error: --name and --content are required');
  process.exit(1);
}

// Build request body for forum post (thread with message)
const body = {
  name: name,
  message: {
    content: content
  }
};

if (tags.length > 0) {
  body.applied_tags = tags;
}

// Create forum post via threads endpoint
const res = await fetch(`https://discord.com/api/v10/channels/${CHANNEL_ID}/threads`, {
  method: 'POST',
  headers: {
    'Authorization': `Bot ${token}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify(body),
});

if (!res.ok) {
  const err = await res.json();
  console.error('❌ Failed:', err.message || JSON.stringify(err, null, 2));
  process.exit(1);
}

const result = await res.json();
console.log('✅ Forum post created!');
console.log('Thread ID:', result.id);
console.log('Name:', result.name);
