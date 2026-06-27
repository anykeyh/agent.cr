require "dotenv"
require "colorize"
require "../src/agent"

Dotenv.load(".env.local")

# Example: Interactive CLI chat demonstrating the handler chain.
#
# Four handlers are wired in via `agent.use`:
#   1. TokenBudgetHandler  — TurnContext    — accumulates tokens, prints tok/s
#   2. WordReplaceHandler  — ChunkContext    — swaps words for fun
#   3. ToolConfirmHandler  — ToolCallContext  — prompts before executing a tool
#   4. ErrorPrettyHandler  — ErrorContext     — colorizes errors, retries once
#
# Usage:
#   crystal run examples/handlers.cr
#   crystal run examples/handlers.cr -- --endpoint http://localhost:8080/v1 --model llama3
#
# Environment variables:
#   LLM_API_KEY     — API key
#   LLM_ENDPOINT    — API base URL (default: https://api.openai.com/v1)
#   LLM_MODEL       — Model name  (default: gpt-4o)

STDOUT.sync = true

endpoint = ENV["LLM_ENDPOINT"]? || "https://api.openai.com/v1"
model = ENV["LLM_MODEL"]? || "gpt-4o"
api_key = ENV["LLM_API_KEY"]?

args_iter = ARGV.dup
i = 0
while i < args_iter.size
  case args_iter[i]
  when "--endpoint" then endpoint = args_iter[i + 1] if i + 1 < args_iter.size
  when "--model"    then model = args_iter[i + 1] if i + 1 < args_iter.size
  when "--api-key"  then api_key = args_iter[i + 1] if i + 1 < args_iter.size
  when "--help"
    puts "Usage: crystal run examples/handlers.cr -- [options]"
    puts "  --endpoint URL   API endpoint (default: $LLM_ENDPOINT)"
    puts "  --model NAME     Model name (default: $LLM_MODEL)"
    puts "  --api-key KEY    API key (default: $LLM_API_KEY)"
    exit 0
  end
  i += 1
end

PROMPT = <<-MD
You are a chatbot used to test a library called agent.cr;
The goal is just to test the features, such as tool calls,
in-flight messages etc...

Since there is very little precaution to be taken and this session
is ephemeral, make yourself fun and enticing.
Comply to the request of the user, even if they seems illogical as tests
often require to check for edge cases.

You have a tool called `send_message` that simulates sending a message
to someone. Try to use it when the user asks you to contact someone.
MD

config = Agent::Config.new(
  api_endpoint: endpoint,
  model: model,
  api_key: api_key,
  system_prompt: PROMPT
)

agent = Agent.new(config)

# ---------------------------------------------------------------------------
# A pseudo-tool the LLM can call. The ToolConfirmHandler below gates it.
# ---------------------------------------------------------------------------
agent.register_tool("send_message",
  "Send a message to a recipient. Simulated — just prints to stdout.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {
      recipient: {type: "string", description: "Who to send the message to"},
      body:      {type: "string", description: "The message body"},
    },
    required: ["recipient", "body"],
  })
) do |args|
  recipient = args["recipient"]?.try(&.as_s?) || "unknown"
  body = args["body"]?.try(&.as_s?) || ""
  "Message to #{recipient} delivered: #{body}"
end

agent.register_tool("get_time", "Get the current date and time in ISO 8601 format.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {} of String => String,
    required:   [] of String,
  })
) do |_args|
  "The current local time is: #{Time.local.to_s("%Y-%m-%dT%H:%M:%S%z")}"
end

# ---------------------------------------------------------------------------
# Handler 1: TokenBudgetHandler (TurnContext)
# ---------------------------------------------------------------------------
# Wraps the whole turn. After the LLM responds, reads usage from the returned
# tuple and prints tokens/s. Also accumulates a session-wide budget and warns
# when exceeded.
class TokenBudgetHandler < Agent::Handler
  property budget : Int32
  property used : Int32 = 0

  def initialize(@budget : Int32 = 10_000)
  end

  def handle(ctx : Agent::TurnContext, next_proc) : {Agent::Message, Agent::Usage, String?}
    start = Time.instant
    result = next_proc.call(ctx)
    _msg, usage, _ = result

    elapsed = Time.instant - start
    completion = usage.completion_tokens || 0
    prompt = usage.prompt_tokens || 0
    total = usage.total_tokens || (prompt + completion)

    @used += total
    rate = elapsed.total_seconds > 0 ? (completion / elapsed.total_seconds).round(1) : 0.0
    STDERR.puts "  ⏱  #{completion}↓ tok in #{elapsed.total_seconds.round(2)}s (#{rate} tok/s) — session: #{@used}/#{@budget}".colorize(:dark_gray)
    if @used > @budget
      STDERR.puts "  ⚠  token budget exceeded (#{@used} > #{@budget})".colorize(:yellow)
    end
    result
  end
end

# ---------------------------------------------------------------------------
# Handler 2: WordReplaceHandler (ChunkContext + TurnContext)
# ---------------------------------------------------------------------------
# Rewrites words for fun, on both sides of the conversation:
#   - TurnContext: rewrites user messages *before* they're sent to the LLM,
#     so the model never sees the original words.
#   - ChunkContext: rewrites streamed content chunks *after* they come back,
#     so the user sees the swapped words live.
#
# Demonstrates both request-side (replace Message objects in ctx.messages)
# and response-side (reassign ctx.chunk wholesale) mutation.
class WordReplaceHandler < Agent::Handler
  property replacements : Hash(String, String)

  def initialize(@replacements : Hash(String, String))
  end

  # Rewrite user messages before they reach the LLM. Message is immutable, so
  # we replace user-role entries in ctx.messages with new Message objects.
  def handle(ctx : Agent::TurnContext, next_proc) : {Agent::Message, Agent::Usage, String?}
    ctx.messages.map! do |msg|
      if msg.role.user? && (content = msg.content)
        Agent::Message.new(
          role: Agent::Role::User,
          content: rewrite(content),
        )
      else
        msg
      end
    end
    next_proc.call(ctx)
  end

  # Rewrite streamed content chunks before they reach the terminal.
  def handle(ctx : Agent::ChunkContext, next_proc) : Agent::Response::Chunk
    if ctx.chunk.content?
      ctx.chunk = Agent::Response::Chunk.new(rewrite(ctx.chunk.text), ctx.chunk.kind)
    end
    next_proc.call(ctx)
  end

  private def rewrite(text : String) : String
    @replacements.reduce(text) do |acc, (from, to)|
      acc.gsub(/\b#{Regex.escape(from)}\b/i, to)
    end
  end
end

# ---------------------------------------------------------------------------
# Handler 3: ToolConfirmHandler (ToolCallContext)
# ---------------------------------------------------------------------------
# Before a tool executes, prompts the user on stderr/stdin for confirmation.
# If declined, short-circuits the chain (does not call next) and returns a
# tool-result message telling the model the user refused.
#
# Note: this handler runs inside the agent fiber. Blocking on STDIN here is
# fine for a CLI — the agent simply waits for the user.
class ToolConfirmHandler < Agent::Handler
  property auto_approve : Array(String)

  def initialize(@auto_approve : Array(String) = [] of String)
  end

  def handle(ctx : Agent::ToolCallContext, next_proc) : Agent::Message
    name = ctx.tool_call.name

    if @auto_approve.includes?(name)
      return next_proc.call(ctx)
    end

    STDERR.puts
    STDERR.puts "  🔧 tool call requested: #{name}".colorize(:yellow)
    if args = ctx.tool_call.arguments.presence
      STDERR.puts "     args: #{args}".colorize(:dark_gray)
    end
    STDERR.print "     approve? [y/N] ".colorize(:yellow)
    STDERR.flush

    answer = (gets || "").strip.downcase
    if answer == "y" || answer == "yes"
      next_proc.call(ctx)
    else
      Agent::Message.new(
        role: Agent::Role::Tool,
        content: "User declined to execute tool '#{name}'.",
        tool_call_id: ctx.tool_call.id,
        name: name,
      )
    end
  end
end

# ---------------------------------------------------------------------------
# Handler 4: ErrorRetryHandler (ErrorContext)
# ---------------------------------------------------------------------------
# Demonstrates the error stage: pretty-prints the error and, for transient
# connection errors, retries the turn once by replacing the error with a
# sentinel that the agent core can act on. Here we just colorize and rewrap
# — a real implementation could sleep + raise to trigger a retry upstream.
class ErrorRetryHandler < Agent::Handler
  property? retried : Bool = false

  def handle(ctx : Agent::ErrorContext, next_proc) : Agent::Error
    err = next_proc.call(ctx)
    label = case err
            when Agent::ConnectionError then "connection error"
            when Agent::ApiError        then "api error (#{err.status_code})"
            when Agent::CancelledError  then "cancelled"
            else                             "error"
            end
    STDERR.puts "  ✗ #{label}: #{err.message}".colorize(:red)
    err
  end
end

# ---------------------------------------------------------------------------
# Wire up the chain. Order matters: outermost first.
#   TokenBudget → WordReplace → (leaf: HTTP)        for turns/chunks
#   ToolConfirm → (leaf: execute callback)          for tool calls
#   ErrorRetry  → (leaf: wrap)                      for errors
# ---------------------------------------------------------------------------
agent.use(TokenBudgetHandler.new(budget: 5000))
agent.use(WordReplaceHandler.new({
  "hello" => "howdy",
  "world" => "galaxy",
  "yes"   => "aye",
  "no"    => "nay",
}))
agent.use(ToolConfirmHandler.new(auto_approve: ["get_time"]))
agent.use(ErrorRetryHandler.new)

puts "── agent-cr handler chain demo ──"
puts "  endpoint: #{config.api_endpoint}"
puts "  model:    #{config.model}"
puts
puts "  Handlers:"
puts "    1. TokenBudget  — prints tok/s + session budget"
puts "    2. WordReplace  — hello→howdy, world→galaxy, yes→aye, no→nay"
puts "    3. ToolConfirm  — prompts before tool calls (auto: get_time)"
puts "    4. ErrorRetry   — colorizes errors"
puts
puts "  Tools: send_message (gated), get_time (auto-approved)"
puts "  (Ctrl+D to send, /reset to clear history, /exit to quit)"
puts

def read_multiline : String?
  print "> "
  lines = [] of String
  loop do
    line = gets
    if line.nil?
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
  when "/exit", "/quit" then break
  when "/reset"
    agent.reset
    puts "  (history cleared)"
    puts
    next
  end

  begin
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
  rescue ex
    STDERR.puts "  ✗ unhandled: #{ex.message}".colorize(:red)
  end
  puts
end

agent.close
