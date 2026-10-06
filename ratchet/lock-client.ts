// SDK owns initialization/tools/call and NDJSON framing over a Unix socket.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { ReadBuffer, serializeMessage } from '@modelcontextprotocol/sdk/shared/stdio.js';
import type { Transport } from '@modelcontextprotocol/sdk/shared/transport.js';
import type { JSONRPCMessage } from '@modelcontextprotocol/sdk/types.js';
import { createConnection, type Socket } from 'node:net';
import { writeFileSync } from 'node:fs';

class UnixTransport implements Transport {
  socket?: Socket;
  buffer = new ReadBuffer();
  onmessage?: Transport['onmessage'];
  onerror?: Transport['onerror'];
  onclose?: Transport['onclose'];
  async start() {
    await new Promise<void>((resolve, reject) => {
      this.socket = createConnection(process.env.VOICELAYER_MCP_SOCKET_PATH!);
      this.socket.once('connect', resolve);
      this.socket.once('error', reject);
      this.socket.on('error', error => this.onerror?.(error));
      this.socket.on('close', () => this.onclose?.());
      this.socket.on('data', chunk => {
        try {
          this.buffer.append(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
          let message: JSONRPCMessage | null;
          while ((message = this.buffer.readMessage()) !== null) this.onmessage?.(message);
        } catch (error) {
          this.onerror?.(error as Error);
          this.socket?.destroy();
        }
      });
    });
  }
  async send(message: JSONRPCMessage) {
    if (!this.socket || this.socket.destroyed) throw new Error('MCP socket closed');
    await new Promise<void>((resolve, reject) => {
      this.socket!.write(serializeMessage(message), error => error ? reject(error) : resolve());
    });
  }
  async close() {
    if (this.socket && !this.socket.destroyed) {
      await new Promise<void>(resolve => {
        this.socket!.once('close', resolve);
        this.socket!.destroy();
      });
    }
    this.buffer.clear();
  }
}

const client = new Client({ name: 'ratchet-lock', version: '1.0.0' });
try {
  await client.connect(new UnixTransport());
  const result = await client.callTool({ name: 'voice_ask', arguments: {
    message: 'Synthetic lock question?', voice: 'en-US-JennyNeural',
    timeout_seconds: 5, silence_mode: 'thoughtful', push_to_end: false,
  } }, undefined, { timeout: 35000 });
  writeFileSync(process.argv[2], JSON.stringify({ completed: true, isError: !!result.isError }));
} finally {
  await client.close();
}
