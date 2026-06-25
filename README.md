# agent-cr

A Crystal shard for building agentic loops with OpenAI-compatible APIs.

## Installation

Add this to your `shard.yml`:

```yaml
dependencies:
  agent-cr:
    github: your-name/agent-cr
```

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

## Streaming

```crystal
resp = agent.ask("Write a short poem about AI.")

resp.stream do |chunk|
  print chunk   # each token as it arrives
end

puts # newline after stream ends
puts resp.message.content        # full text
puts resp.metadata.total_tokens  # token usage
```

## Conversation history

History is tracked automatically — each `#ask` appends the user message, and the
agent's reply is added to the conversation.

```crystal
agent.ask("My name is Alice.").join
agent.ask("What is my name?").join

puts agent.history.size # => 4 (user, assistant, user, assistant)
```

To start a fresh conversation without creating a new agent:

```crystal
agent.reset
```

## Multimodal (images)

```crystal
resp = agent.ask(
  "What's in this image?",
  images: ["https://example.com/photo.jpg"]
)
resp.join
```

## Tools / function calling

### Registered tools (auto-resolve) — recommended

Register tools with a callback block. The agent automatically resolves tool
calls inline — no manual while-loop needed.

```crystal
# Define the JSON Schema parameters using a plain Crystal NamedTuple
params = Agent::JSONSchema.from({
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
resp.stream { |chunk| print chunk }
puts resp.message.content # => "The weather in Paris is sunny."
```

You can `register_tool` multiple times. All registered tools are merged into
every request automatically.

To disable auto-resolution (e.g. if you want to handle tool calls manually):

```crystal
config = Agent::Config.new(
  api_key: ENV["OPENAI_API_KEY"],
  auto_execute_tools: false
)
```

With `auto_execute_tools: false`, the agent returns tool calls to the caller
as before, and you handle them manually with the legacy API below.

### Legacy tools (manual dispatch)

```crystal
weather_tool = Agent::Tool.new(Agent::Tool::FunctionDef.new(
  name: "get_weather",
  description: "Get the current weather for a city",
  parameters: {
    "type"     => JSON::Any.new("object"),
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

if resp.message.has_tool_calls?
  resp.message.tool_calls.not_nil!.each do |tc|
    puts "Tool: #{tc.name}(#{tc.arguments})"
  end
end
```

To feed results back to the model:

```crystal
results = resp.message.tool_calls.not_nil!.map do |tc|
  Agent::Message.new(
    role: "tool",
    content: execute_tool(tc),
    tool_call_id: tc.id,
    name: tc.name,
  )
end

final = agent.ask(results, tools: [weather_tool])
final.stream { |chunk| print chunk }
```

### Tool call ordering

Tool calls always arrive as a single assistant message with
`finish_reason: "tool_calls"`. The model does not interleave content and tool
calls within a single turn. When using registered tools with
`auto_execute_tools: true`, the agent loops internally: ask → tool calls →
execute → ask again — until the model responds with content.

## Response API

| Method | Description |
|--------|-------------|
| `.stream { \|chunk\| }` | Yield text deltas as they arrive |
| `.message` | Wait for and return the final `Message` |
| `.metadata` | Wait for and return `Usage` (token counts) |
| `.join` | Block until both message and metadata are ready |
| `.finished?` | Poll whether the response is complete |
| `.finish_reason` | Why the stream ended (`"stop"`, `"length"`, `"tool_calls"`, etc.) |

## Configuration

```crystal
Agent::Config.new(
  api_key:            String,           # required
  api_endpoint:       String,           # default: "https://api.openai.com/v1"
  model:              String,           # default: "gpt-4o"
  system_prompt:      String?,          # optional system message
  max_tokens:         Int32?,           # optional max completion tokens
  temperature:        Float64?,         # optional sampling temperature
  read_timeout:       Time::Span?,      # optional HTTP read timeout
  connect_timeout:    Time::Span?,      # optional HTTP connect timeout
  max_history:        Int32?,           # optional max conversation turns
  auto_execute_tools: Bool,             # default: true
)
```

## License

MIT