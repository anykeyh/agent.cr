# agent-cr

A Crystal shard for building agentic loops with OpenAI-compatible APIs.

`agent-cr` wraps any OpenAI-compatible streaming chat-completion endpoint behind a fiber-based async interface. It handles streaming, tool calls, multimodal content, conversation history, and automatic tool resolution — all in a background fiber so your code never blocks.

---

## Installation

Add this to your `shard.yml`:

```yaml
dependencies:
  agent-cr:
    github: anykeyh/agent-cr
```

Then run:

```sh
shards install
```

> Built with Crystal >= 1.20.2+

---

## Quick start

```crystal
require "agent"

config = Agent::Config.new(
  api_key: ENV["OPENAI_API_KEY"],
  system_prompt: "You are a helpful assistant."
)

agent = Agent.new(config)
resp = agent.ask("What is the capital of France?")

puts resp.message.content # => "The capital of France is Paris."
```

The `#ask` call returns immediately (the HTTP request runs in a background fiber). Calling `.message` blocks until the full response is ready.

---

## Streaming

When you want to show tokens as they arrive, use `.stream`:

```crystal
resp = agent.ask("Write a short poem about AI.")

resp.stream do |chunk|
  print chunk.text  # each token as it arrives
end

puts # newline after stream ends

# The final message is still available after streaming:
puts resp.message.content
puts "Used #{resp.metadata.total_tokens} tokens"
```

### Chunk kinds

Each chunk is tagged with its origin via `chunk.kind`:

```crystal
resp.stream do |chunk|
  case chunk.kind
  when Agent::Response::ChunkKind::Content
    print chunk.text
  when Agent::Response::ChunkKind::Reasoning
    print "\e[2m#{chunk.text}\e[0m"  # dimmed for reasoning
  when Agent::Response::ChunkKind::ToolCallName
    puts "\n[Calling tool: #{chunk.text}]"
  when Agent::Response::ChunkKind::ToolCallArgs
    # tool argument deltas
  end
end
```

---

## Conversation history

History is tracked automatically — each `#ask` appends the user message, and the agent's reply is added to the conversation.

```crystal
agent.ask("My name is Alice.").join
agent.ask("What is my name?").join

puts agent.history.size # => 4 (user, assistant, user, assistant)
```

### Reset

Start a fresh conversation without creating a new agent:

```crystal
agent.reset
```

### History trimming

Set `max_history` to limit the number of conversation turns kept in memory. The agent trims complete turn units (never orphaning tool messages).

```crystal
config = Agent::Config.new(
  api_key: ENV["OPENAI_API_KEY"],
  max_history: 10   # keep at most 10 user+assistant turns
)
```

### Save and restore sessions

Serialise a session (including cache key for prompt caching affinity):

```crystal
# Save
File.write("session.json", agent.dump)

# Restore
config = Agent::Config.new(api_key: ENV["OPENAI_API_KEY"])
agent = Agent.load(config, File.read("session.json"))
agent.ask("Continue where we left off")  # 🚀 cache hit
```

---

## Attachments (multimodal)

Pass file paths, URLs, or data URIs as `attachments`. Local files are
auto-detected by extension: images become `image_url` parts, text files
are inlined, audio becomes `input_audio`, and everything else is sent as
`file` parts.

```crystal
# Remote image URL
resp = agent.ask(
  "What's in this image?",
  attachments: ["https://example.com/photo.jpg"]
)
resp.join
puts resp.message.content

# Local file — MIME auto-detected from extension
resp = agent.ask(
  "Review this document",
  attachments: ["./doc.md"]
)
```

See `Agent::ContentPart.from_path` for the MIME detection rules.

---

## Tools / function calling

### Registered tools with auto-resolve (recommended)

Register tools with a callback block. The agent automatically resolves tool calls inline — no manual while-loop needed.

```crystal
# Define JSON Schema parameters using a plain Crystal NamedTuple
params = Agent::JSONConverter.from({
  type: "object",
  properties: {
    city: {type: "string", description: "The city name"},
  },
  required: ["city"],
})

agent.register_tool("get_weather", "Get the current weather for a city",
  parameters: params
) do |args|
  city = args["city"]?.try(&.as_s) || "unknown"
  "The weather in #{city} is sunny."
end

# Registered tools are automatically included in all #ask calls.
# When the model calls a tool, the agent executes it and re-asks the
# model — all in the background fiber. The Response you get back is
# the final one (after all tool resolutions).
resp = agent.ask("What's the weather in Paris?")
resp.stream { |chunk| print chunk.text }
puts resp.message.content # => "The weather in Paris is sunny."
```

You can `register_tool` multiple times. All registered tools are merged into every request automatically. If a per-request tool has the same name as a registered tool, the registered callback wins.

### Disable auto-resolve

To handle tool calls manually (e.g. only some tools are registered, or you need user approval):

```crystal
config = Agent::Config.new(
  api_key: ENV["OPENAI_API_KEY"],
  auto_execute_tools: false
)
```

With `auto_execute_tools: false`, the agent returns tool calls to the caller and you dispatch manually:

```crystal
resp = agent.ask("What's the weather in Paris?")
resp.join

if resp.message.has_tool_calls?
  resp.message.tool_calls.not_nil!.each do |tc|
    puts "Tool: #{tc.name}(#{tc.arguments})"
  end
end
```

### Legacy manual dispatch

You can also pass tools per-request without registering them:

```crystal
weather_tool = Agent::Tool.new(Agent::Tool::FunctionDef.new(
  name: "get_weather",
  description: "Get the current weather for a city",
  parameters: {
    "type"       => JSON::Any.new("object"),
    "properties" => JSON::Any.new({
      "city" => JSON::Any.new({"type" => JSON::Any.new("string")}),
    }),
  }
))

resp = agent.ask(
  "What's the weather in Paris?",
  tools: [weather_tool]
)
resp.join
```

To feed results back to the model:

```crystal
results = resp.message.tool_calls.not_nil!.map do |tc|
  Agent::Message.new(
    role: Agent::Role::Tool,
    content: execute_tool(tc),
    tool_call_id: tc.id,
    name: tc.name,
  )
end

final = agent.ask(results, tools: [weather_tool])
final.stream { |chunk| print chunk.text }
```

---

## Provider system

`agent-cr` uses a pluggable provider abstraction. The default provider is `Agent::Provider::OpenAI`, which works with any OpenAI-compatible API (OpenAI, Anthropic via proxy, local llama.cpp, Ollama, etc.).

### Switch endpoint for a compatible API

```crystal
# Any OpenAI-compatible endpoint works:
config = Agent::Config.new(
  api_key: "not-needed",
  api_endpoint: "http://localhost:8080/v1",
  model: "local-model",
)
```

### Custom provider

Implement `Agent::Provider::Base` to support a different wire format:

```crystal
class MyProvider < Agent::Provider::Base
  def base_uri : URI
    URI.parse("https://myapi.com/v1")
  end

  def build_request(messages, tools) : NamedTuple(path: String, headers: HTTP::Headers, body: String)
    # Build path, auth headers, and JSON body
    {path: "/chat", headers: HTTP::Headers{"X-API-Key" => "secret"}, body: my_body.to_json}
  end

  def parse_stream(io, response, cancel) : {Message, Usage, String?}
    # Parse response body, push chunks, return final message
  end

  def close : Nil
  end
end

agent = Agent.new(config, provider: MyProvider.new(...))
```

---

## Response API

| Method / Property | Description |
|---|---|
| `.stream { \|chunk\| }` | Yield each delta as it arrives from the API |
| `.message` | Block until the final `Message` is ready, then return it |
| `.metadata` | Block until `Usage` (token counts) is ready, then return it |
| `.join` | Block until both message and metadata are ready |
| `.finished?` | Poll whether the response is complete |
| `.error?` | Whether the response represents a failed request |
| `.error` | The `Agent::Error` if the request failed, or `nil` |
| `.finish_reason` | Why the stream ended (`"stop"`, `"length"`, `"tool_calls"`, etc.) |
| `.cancel` | Request cancellation of the in-flight request |
| `.cancelled?` | Whether cancellation was requested |

### Message fields

```crystal
msg = resp.message
msg.content        # String? — text content
msg.reasoning      # String? — reasoning content (DeepSeek, Qwen, etc.)
msg.role           # Agent::Role — System, User, Assistant, Tool
msg.tool_calls     # Array(ToolCall)? — function calls from the model
msg.tool_call_id   # String? — id for tool result messages
msg.content_parts  # Array(ContentPart)? — multimodal parts (text + images)
msg.has_tool_calls? # Bool — convenience check
```

---

## Configuration

```crystal
Agent::Config.new(
  api_key:            String?,             # OpenAI API key (or nil for local models)
  api_endpoint:       String,              # default: "https://api.openai.com/v1"
  model:              String,              # default: "gpt-4o"
  system_prompt:      String?,             # optional system message prepended to every request
  max_tokens:         Int32?,              # optional max completion tokens
  temperature:        Float64?,            # optional sampling temperature (0.0-2.0)
  read_timeout:       Time::Span | Int32?, # optional HTTP read timeout (seconds or span)
  connect_timeout:    Time::Span | Int32?, # optional HTTP connect timeout (seconds or span)
  max_history:        Int32?,              # optional max conversation turns (0 disables)
  auto_execute_tools: Bool,                # default: true
  extra_headers:      Hash(String, String)?, # optional extra HTTP headers
  max_tool_iterations: Int32?,             # default: 100 — safety limit for tool loops
  prompt_cache_key:   String?,             # optional explicit prompt cache key
)
```

---

## Error handling

Errors provide a consistent `"Agent error: ..."` prefix on the message content, so you can pattern-match programmatically:

```crystal
resp = agent.ask("Hello")
resp.join

if resp.error?
  puts "Request failed: #{resp.error.message}"
  puts resp.error.class  # Agent::ConnectionError, Agent::ApiError, etc.
else
  puts resp.message.content
end
```

Error types:

| Error | When |
|---|---|
| `Agent::ApiError` | API returned a non-2xx status code (includes `.status_code`) |
| `Agent::ConnectionError` | Network / connection failure |
| `Agent::CancelledError` | Caller called `.cancel` on the response |
| `Agent::ToolLoopError` | Tool auto-resolve exceeded `max_tool_iterations` |

---

## Best practices

### Timeouts

Set timeouts in production — the defaults are unbounded:

```crystal
config = Agent::Config.new(
  api_key: ENV["OPENAI_API_KEY"],
  read_timeout: 30.seconds,
  connect_timeout: 10.seconds,
)
```

### Cleanup

Close the agent when done to shut down the background fiber and release the HTTP connection pool:

```crystal
agent.close
```

### Prompt caching

When using APIs that support prompt caching (e.g. OpenAI, DeepSeek), set an explicit `prompt_cache_key` or use `Agent.load` to restore a previous session — both preserve cache affinity:

```crystal
# Auto-generated cache key tied to the session
agent = Agent.new(config)
# vs restored session with the same cache_key
agent = Agent.load(config, saved_session_string)
```

---

## Contributing

See [AGENTS.md](AGENTS.md) for the architecture overview and development workflow.

### Quick commands

```sh
shards install           # install dependencies
crystal spec             # run tests
crystal tool format      # format code
bin/ameba                # lint
```

---

## License

MIT
