"""Loopback-only wire fixture. Never accepts or logs real credentials."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

records = []
output = Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        messages = request.get('messages', [])
        result = next((m for m in reversed(messages) if m.get('role') == 'tool'), None)
        expected = 'Bearer knarr-hive-wire-synthetic-only'
        record = dict(path=self.path, model=request.get('model'),
                      reasoning=request.get('reasoning_effort'), stream=request.get('stream'),
                      authorizationMatched=self.headers.get('Authorization') == expected,
                      toolContinuation=result is not None,
                      reasoningRetained=any(m.get('reasoning_content') == 'Check the nonce.' for m in messages),
                      outputBudget=request.get('max_completion_tokens'),
                      toolNamed=any(t.get('function', {}).get('name') == 'knarr_hive_probe' for t in request.get('tools', [])))
        records.append(record)
        output.write_text(json.dumps(records))
        if not record['authorizationMatched']:
            self.send_error(401, 'Synthetic fixture credential required')
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()

        def chunk(delta, finish=None):
            self.wfile.write(('data: ' + json.dumps(dict(id='hive-wire', object='chat.completion.chunk',
                model='deepseek-ai/deepseek-v4.1-flash-1017', choices=[dict(index=0, delta=delta, finish_reason=finish)])) + '\n\n').encode())
            self.wfile.flush()

        if not record['toolNamed']:
            chunk(dict(role='assistant', reasoning_content='Check the request.', content='HIVE_HIRD_FIXTURE_OK'))
            chunk({}, 'stop')
        elif result is None:
            chunk(dict(role='assistant', reasoning_content='Check the nonce.'))
            chunk(dict(tool_calls=[dict(index=0, id='hive-tool-1', type='function', function=dict(name='knarr_hive_probe', arguments='{'))]))
            chunk(dict(tool_calls=[dict(index=0, function=dict(arguments='}'))]))
            chunk({}, 'tool_calls')
        else:
            content = result.get('content', '')
            if isinstance(content, list):
                content = ''.join(p.get('text', '') for p in content)
            chunk(dict(role='assistant', content=content))
            chunk({}, 'stop')
        self.wfile.write(b'data: {"id":"hive-wire","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":10,"total_tokens":22,"completion_tokens_details":{"reasoning_tokens":4}}}\n\ndata: [DONE]\n\n')
        self.wfile.flush()
        self.close_connection = True


server = HTTPServer(('127.0.0.1', 0), Handler)
Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
