// SDK owns initialize/tools/call and response validation; socat bridges NDJSON.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { writeFileSync } from 'node:fs';
const client = new Client({ name: 'ratchet-lock', version: '1.0.0' });
const transport = new StdioClientTransport({
  command: 'socat', args: ['STDIO', `UNIX-CONNECT:${process.env.VOICELAYER_MCP_SOCKET_PATH}`],
});
try {
  await client.connect(transport);
  const result = await client.callTool({ name: 'voice_ask', arguments: {
    message: 'Synthetic lock question?', voice: 'en-US-JennyNeural',
    timeout_seconds: 5, silence_mode: 'thoughtful', push_to_end: false,
  } }, undefined, { timeout: 45000 });
  writeFileSync(process.argv[2], JSON.stringify({ completed: true, isError: !!result.isError }));
} finally {
  await client.close();
}
