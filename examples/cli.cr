require "colorize"
require "../src/agent"

# Example: Minimal interactive CLI chat with streaming output and registered tools.
#
# Usage:
#   crystal run examples/cli.cr
#   crystal run examples/cli.cr -- --endpoint http://localhost:8080/v1 --model llama3
#
# Multi-line input: press Ctrl+D on an empty line to send the message.
#   /reset       — clear conversation history
#   /exit, /quit — quit
#
# Environment variables:
#   LLM_API_KEY     — API key (optional for local endpoints)
#   LLM_ENDPOINT    — API base URL (default: http://ai.local.amplitude-solutions.com/llm/)
#   LLM_MODEL       — Model name  (default: gpt-4o)

endpoint = ENV["LLM_ENDPOINT"]? || "http://ai.local.amplitude-solutions.com/llm/"
model = ENV["LLM_MODEL"]? || "gpt-4o"
api_key = ENV["LLM_API_KEY"]?

# Parse `--key value` CLI arguments
args = ARGV.dup
i = 0
while i < args.size
  case args[i]
  when "--endpoint" then endpoint = args[i + 1] if i + 1 < args.size
  when "--model"    then model = args[i + 1] if i + 1 < args.size
  when "--api-key"  then api_key = args[i + 1] if i + 1 < args.size
  end
  i += 1
end

config = Agent::Config.new(
  api_endpoint: endpoint,
  model: model,
  api_key: api_key,
  system_prompt: "You are a helpful assistant. Keep your answers concise."
)

agent = Agent.new(config)

# Register tools with callbacks — the agent will auto-resolve tool calls inline.
# No manual tool-call while-loop needed!
# `Agent::JSONSchema.from` converts a Crystal NamedTuple/Hash to JSON::Any
# automatically — no JSON::Any.new(...) boilerplate.
agent.register_tool("get_time", "Get the current date and time in ISO 8601 format (e.g. 2026-06-25T10:30:00Z). Returns the local time.",
  parameters: Agent::JSONSchema.from({
    type:       "object",
    properties: {} of String => String,
    required:   [] of String,
  })
) do |_args|
  "The current local time is: #{Time.local.to_s("%Y-%m-%dT%H:%M:%S%z")}"
end

puts "── agent-cr interactive chat (with registered tools) ──"
puts "  endpoint: #{config.api_endpoint}"
puts "  model:    #{config.model}"
puts "  (Ctrl+D to send, /reset to clear history, /exit to quit)"
puts

# Reads one multi-line message from stdin. Returns nil on EOF.
def read_multiline : String?
  print "> "
  lines = [] of String
  loop do
    line = gets
    if line.nil?
      # EOF (Ctrl+D)
      puts if lines.empty?
      break
    end
    lines << line
  end
  return nil if lines.empty?
  lines.join("\n")
end

loop do
  input = read_multiline
  break unless input

  case input.strip
  when "/exit", "/quit"
    break
  when "/reset"
    agent.reset
    puts "  (history cleared)"
    puts
    next
  end

  begin
    # The agent automatically includes registered tools in every call.
    # When the model requests a tool, the agent executes it and re-asks
    # the model — all transparently. The Response you get back is the
    # final one (after all tool resolutions).
    response = agent.ask(input)
    STDOUT.sync = true

    response.stream do |chunk|
      if chunk.reasoning?
        STDOUT.print chunk.text.colorize(:dark_gray)
      else
        STDOUT.print chunk.text
      end
    end

    STDOUT.puts

    meta = response.metadata
    if (p = meta.prompt_tokens) && (c = meta.completion_tokens)
      puts "  ── tokens: #{p}↑ #{c}↓"
    end
  rescue ex
    STDERR.puts "  ✗ error: #{ex.message}"
  end
  puts
end
