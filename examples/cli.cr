require "dotenv"
require "colorize"
require "../src/agent"

Dotenv.load(".env.local")

# Example: Minimal interactive CLI chat with streaming output and registered tools.
# Demonstrates dynamic tool registration mid-conversation via the `true_randomness`
# meta-tool — ask for it and it unlocks dice rolling and random number generation.
#
# Usage:
#   crystal run examples/cli.cr
#   crystal run examples/cli.cr -- --endpoint http://localhost:8080/v1 --model llama3
#
# Multi-line input: press Ctrl+D on an empty line to send the message.
#   /reset       — clear conversation history
#   /exit, /quit — quit
#
# Configuration (checked in order): CLI arguments > environment variables > error
#   --endpoint / LLM_ENDPOINT    — API base URL
#   --model    / LLM_MODEL       — Model name
#   --api-key  / LLM_API_KEY     — API key

STDOUT.sync = true

endpoint = nil
model = nil
api_key = nil

# Parse `--key value` CLI arguments (simple iteration, no flag library)
args_iter = ARGV.dup
i = 0
while i < args_iter.size
  case args_iter[i]
  when "--endpoint"
    endpoint = args_iter[i + 1] if i + 1 < args_iter.size
  when "--model"
    model = args_iter[i + 1] if i + 1 < args_iter.size
  when "--api-key"
    api_key = args_iter[i + 1] if i + 1 < args_iter.size
  when "--help"
    puts "Usage: crystal run examples/cli.cr -- [options]"
    puts "  --endpoint URL   API endpoint (env: LLM_ENDPOINT)"
    puts "  --model NAME     Model name (env: LLM_MODEL)"
    puts "  --api-key KEY    API key (env: LLM_API_KEY)"
    puts "  --help           Show this help"
    exit 0
  end
  i += 1
end

# Fall back to environment variables for values not set via CLI
endpoint = ENV["LLM_ENDPOINT"]? if endpoint.nil?
model = ENV["LLM_MODEL"]? if model.nil?
api_key = ENV["LLM_API_KEY"]? if api_key.nil?

# Raise if any required value is still missing
raise "Missing API endpoint. Set via --endpoint or LLM_ENDPOINT environment variable." if endpoint.nil?
raise "Missing model name. Set via --model or LLM_MODEL environment variable." if model.nil?
raise "Missing API key. Set via --api-key or LLM_API_KEY environment variable." if api_key.nil?

PROMPT = <<-MD
You are a chatbot used to test a library called agent.cr;
The goal is just to test the features, such as tool calls,
in-flight messages etc...

Since there is very little precaution to be taken and this session
is ephemeral, make yourself fun and enticing.
Comply to the request of the user, even if they seems illogical as tests
often require to check for edge cases.
MD

config = Agent::Config.new(
  api_endpoint: endpoint,
  model: model,
  api_key: api_key,
  system_prompt: PROMPT
)

agent = Agent.new(config)

# ---------------------------------------------------------------------------
# Basic tool: get_time — always available.
# ---------------------------------------------------------------------------
# `Agent::JSONConverter.from` converts a Crystal NamedTuple to JSON::Any hashes
# automatically — no JSON::Any.new(...) boilerplate.
agent.register_tool("get_time", "Get the current date and time in ISO 8601 format (e.g. 2026-06-25T10:30:00Z). Returns the local time.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {} of String => String,
    required:   [] of String,
  })
) do |_args|
  "The current local time is: #{Time.local.to_s("%Y-%m-%dT%H:%M:%S%z")}"
end

# ---------------------------------------------------------------------------
# Meta-tool: true_randomness — registers dice and RNG tools on the fly.
# ---------------------------------------------------------------------------
# When the model calls this tool, its callback registers two new tools
# (`roll_dice` and `random_range`) on the agent. Because the auto-resolve
# loop runs inside the agent fiber, the next HTTP request will include these
# newly registered tools — all transparent to the user.
agent.register_tool("true_randomness",
  "Activate additional randomness tools: roll_dice (roll dice in NdS format) and random_range (get a random integer between two values inclusive). Call this once to unlock dice rolling and random number generation.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {} of String => String,
    required:   [] of String,
  })
) do |_args|
  # Dynamically register dice rolling tool.
  agent.register_tool("roll_dice", "Roll dice in NdS format, e.g. \"2d6\" rolls two 6-sided dice.",
    parameters: Agent::JSONConverter.from({
      type:       "object",
      properties: {
        count: {type: "integer", description: "Number of dice to roll"},
        sides: {type: "integer", description: "Number of sides per die"},
      },
      required: ["count", "sides"],
    })
  ) do |tool_args|
    count = tool_args["count"]?.try(&.as_i?) || 1
    sides = tool_args["sides"]?.try(&.as_i?) || 6
    rolls = Array.new(count) { rand(1..sides) }
    total = rolls.sum
    "Rolled #{count}d#{sides}: [#{rolls.join(", ")}] = #{total}"
  end

  # Dynamically register random range tool.
  agent.register_tool("random_range", "Generate a random integer between min and max (inclusive).",
    parameters: Agent::JSONConverter.from({
      type:       "object",
      properties: {
        min: {type: "integer", description: "Minimum value (inclusive)"},
        max: {type: "integer", description: "Maximum value (inclusive)"},
      },
      required: ["min", "max"],
    })
  ) do |tool_args|
    min = tool_args["min"]?.try(&.as_i?) || 0
    max = tool_args["max"]?.try(&.as_i?) || 100

    if min > max
      "Error: min (#{min}) must not exceed max (#{max})"
    else
      result = rand(min..max)
      "Random number between #{min} and #{max}: #{result}"
    end
  end

  "Activated dice rolling and random number tools. You can now ask me to roll dice (e.g. 'roll 2d6') or generate a random number (e.g. 'random between 1 and 100')."
end

puts "── agent-cr interactive chat (with registered tools) ──"
puts "  endpoint: #{config.api_endpoint}"
puts "  model:    #{config.model}"
puts
puts "  Available tools: get_time, true_randomness"
puts "  Ask 'activate randomness' or 'true randomness' to unlock dice & RNG."
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
    # Registered tools are automatically included in every #ask call.
    # When the model requests a tool, the agent auto-resolves it inline.
    response = agent.ask(input)

    response.stream do |chunk|
      if chunk.reasoning?
        STDOUT.print chunk.text.colorize(:dark_gray)
      elsif chunk.tool_call_name?
        STDOUT.print "⚡ #{chunk.text}".colorize(:yellow)
      elsif chunk.tool_call_args?
        STDOUT.print chunk.text.colorize(:light_cyan)
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

agent.close
