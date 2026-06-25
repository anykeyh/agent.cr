require "colorize"
require "../src/agent"

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

PROMPT = <<-MD
You are a chatbot used to test a library called agent.cr;
The goal is just to test the features, such as tool calls,
in-flight messages etc...

Since there is very little precaution to be taken and this session
is ephemereal, make yourself fun and enticing.
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
# `Agent::JSONSchema.from` converts a Crystal NamedTuple to JSON::Any hashes
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

# ---------------------------------------------------------------------------
# Meta-tool: true_randomness — registers dice and RNG tools on the fly.
# ---------------------------------------------------------------------------
# When the model calls this tool, its callback registers two new tools
# (`roll_dice` and `random_range`) on the agent. Because the auto-resolve
# loop runs inside the agent fiber, the next HTTP request will include these
# newly registered tools — all transparent to the user.
agent.register_tool("true_randomness",
  "Activate additional randomness tools: roll_dice (roll dice in NdS format) and random_range (get a random integer between two values inclusive). Call this once to unlock dice rolling and random number generation.",
  parameters: Agent::JSONSchema.from({
    type:       "object",
    properties: {} of String => String,
    required:   [] of String,
  })
) do |_args|
  # Dynamically register dice rolling tool.
  agent.register_tool("roll_dice", "Roll dice in NdS format, e.g. \"2d6\" rolls two 6-sided dice.",
    parameters: Agent::JSONSchema.from({
      type: "object",
      properties: {
        count: {type: "integer", description: "Number of dice to roll"},
        sides: {type: "integer", description: "Number of sides per die"},
      },
      required: ["count", "sides"],
    })
  ) do |args|
    count = args["count"]?.try(&.as_i) || 1
    sides = args["sides"]?.try(&.as_i) || 6
    rolls = Array.new(count) { rand(1..sides) }
    total = rolls.sum
    "Rolled #{count}d#{sides}: [#{rolls.join(", ")}] = #{total}"
  end

  # Dynamically register random range tool.
  agent.register_tool("random_range", "Generate a random integer between min and max (inclusive).",
    parameters: Agent::JSONSchema.from({
      type: "object",
      properties: {
        min: {type: "integer", description: "Minimum value (inclusive)"},
        max: {type: "integer", description: "Maximum value (inclusive)"},
      },
      required: ["min", "max"],
    })
  ) do |args|
    min = args["min"]?.try(&.as_i) || 0
    max = args["max"]?.try(&.as_i) || 100
    result = rand(min..max)
    "Random number between #{min} and #{max}: #{result}"
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
    STDOUT.sync = true

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
