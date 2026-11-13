#!/usr/bin/env bun
// Real MCP SDK sessions across explicitly supplied gated swap/restore commands. No media tools.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { createServer, createConnection } from 'node:net';
import { readFileSync, writeFileSync, unlinkSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';
import { z } from 'zod';

const [receiptPath, commandsPath] = process.argv.slice(2);
if (!receiptPath || !commandsPath) throw Error('Usage: bun scripts/verify-runtime-bridge.mjs RECEIPT COMMANDS.json');
const commands = z.array(z.array(z.string()).min(1)).min(1).parse(JSON.parse(readFileSync(commandsPath, 'utf8')));
const bridge = process.env.VOICELAYER_BRIDGE_EXECUTABLE ?? '/opt/homebrew/bin/voicelayer-mcp-bridge';
const liveSocket = process.env.VOICELAYER_BRIDGE_LIVE_SOCKET ?? '/tmp/voicelayer-mcp.sock';
const proxyPath = `${tmpdir()}/vl-l8-${process.pid}.sock`;
const connections = new Set();
const clients = [];
const receipt = { status: 'RUNNING', stages: [], bridge, liveSocket };
const save = () => writeFileSync(receiptPath, JSON.stringify(receipt, null, 2) + '\n', { mode: 0o600 });
let heldId, releaseObserved, holdNext = false, forwarded = 0;
process.umask(0o077);
const proxy = createServer(downstream => {
  const upstream = createConnection(liveSocket);
  for (const socket of [upstream, downstream]) {
    connections.add(socket); socket.on('close', () => connections.delete(socket));
    socket.on('error', () => { upstream.destroy(); downstream.destroy(); });
  }
  upstream.on('close', () => downstream.destroy());
  downstream.on('close', () => upstream.destroy());
  let requests = '', replies = '';
  downstream.on('data', data => {
    requests += data.toString();
    let newline;
    while ((newline = requests.indexOf('\n')) >= 0) {
      const line = requests.slice(0, newline); requests = requests.slice(newline + 1);
      const frame = JSON.parse(line);
      if (frame.method === 'tools/list' && (holdNext || frame.id === heldId)) { heldId = frame.id; holdNext = false; forwarded++; }
      upstream.write(line + '\n');
    }
  });
  upstream.on('data', data => {
    replies += data.toString();
    let newline;
    while ((newline = replies.indexOf('\n')) >= 0) {
      const line = replies.slice(0, newline); replies = replies.slice(newline + 1);
      if (JSON.parse(line).id === heldId && heldId !== undefined) { if (JSON.parse(line).result?.tools) releaseObserved?.(); continue; }
      downstream.write(line + '\n');
    }
  });
});
async function session(socket) {
  const transport = new StdioClientTransport({ command: process.execPath, args: [bridge],
    env: { ...process.env, VOICELAYER_MCP_SOCKET_PATH: socket }, stderr: 'pipe' });
  const client = new Client({ name: 'L8-runtime-acceptance', version: '1' });
  clients.push(client);
  await client.connect(transport);
  return { client, transport, pid: transport.pid, preSendRefusals: 0 };
}
async function tools(session) {
  const deadline = performance.now() + 15000;
  for (;;) {
    try {
      const result = await session.client.listTools({}, { timeout: 15000 });
      if (!result.tools.length || session.pid !== session.transport.pid) throw Error('bridge identity/tool listing failed');
      return { bridgePid: session.pid, toolCount: result.tools.length, preSendRefusals: session.preSendRefusals };
    } catch (error) {
      // These requests were explicitly NOT SENT. Never retry an interrupted/executed request.
      if (error.code !== -32000 || !error.message.includes('request was not sent') || performance.now() >= deadline) throw error;
      session.preSendRefusals++;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
  }
}
async function command(argv) {
  await new Promise((resolve, reject) => {
    const child = spawn(argv[0], argv.slice(1), { env: process.env, stdio: 'inherit' });
    child.on('error', reject);
    child.on('exit', code => code === 0 ? resolve() : reject(Error(`gated command exit ${code}`)));
  });
}
try {
  await new Promise(resolve => proxy.listen(proxyPath, resolve));
  const direct = await session(liveSocket), latched = await session(proxyPath);
  receipt.stages.push({ phase: 'baseline', ...await tools(direct), latchedBridgePid: latched.pid }); save();
  for (const [index, argv] of commands.entries()) {
    const observed = new Promise(resolve => { releaseObserved = resolve; });
    heldId = undefined; holdNext = true;
    const pending = latched.client.listTools({}, { timeout: 120000 }).then(() => ({ unexpectedSuccess: true }), error => ({ code: error.code }));
    await Promise.race([observed, new Promise((_, reject) => setTimeout(() => reject(Error('live tool-list response latch timed out')), 10000))]);
    await command(argv);
    const interrupted = await pending;
    if (interrupted.code !== -32000 || forwarded !== index + 1) throw Error('interrupted request semantics failed');
    receipt.stages.push({ phase: `replacement-${index + 1}`, ...await tools(direct),
      latched: await tools(latched), interruptedCode: interrupted.code, forwardedHeldRequestCount: forwarded }); save();
  }
  receipt.status = 'PASS'; save();
} catch (error) {
  receipt.status = 'FAIL'; receipt.error = error.message; save(); throw error;
} finally {
  for (const client of clients) await client.close();
  for (const socket of connections) socket.destroy();
  await new Promise(resolve => proxy.close(resolve));
  try { unlinkSync(proxyPath); } catch {}
}
