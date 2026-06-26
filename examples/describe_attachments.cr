require "colorize"
require "../src/agent"

# Example: Describe attachments using a multimodal model.
#
# Pass one or more file paths, URLs, or data URIs. The agent auto-detects
# MIME types and reads local files automatically.
#
# Usage:
#   crystal run examples/describe_attachments.cr -- https://example.com/photo.jpg
#   crystal run examples/describe_attachments.cr -- ./photo.jpg ./doc.md sound.wav
#   crystal run examples/describe_attachments.cr -- ./doc.pdf --model gpt-4o
#
# Environment variables:
#   LLM_API_KEY     — API key (optional for local endpoints)
#   LLM_ENDPOINT    — API base URL (default: http://ai.local.amplitude-solutions.com/llm/)
#   LLM_MODEL       — Model name  (default: gpt-4o)

STDOUT.sync = true

endpoint = ENV["LLM_ENDPOINT"]? || "http://ai.local.amplitude-solutions.com/llm/"
model = ENV["LLM_MODEL"]? || "gpt-4o"
api_key = ENV["LLM_API_KEY"]?

sources = [] of String

args_iter = ARGV.dup
i = 0
while i < args_iter.size
  case args_iter[i]
  when "--endpoint"
    endpoint = args_iter[i + 1] if i + 1 < args_iter.size
    i += 2
  when "--model"
    model = args_iter[i + 1] if i + 1 < args_iter.size
    i += 2
  when "--api-key"
    api_key = args_iter[i + 1] if i + 1 < args_iter.size
    i += 2
  when "--help"
    puts "Usage: crystal run examples/describe_attachments.cr -- [source ...] [options]"
    puts
    puts "Arguments:"
    puts "  source ...            One or more URLs or local file paths"
    puts
    puts "Options:"
    puts "  --endpoint URL        API endpoint (default: $LLM_ENDPOINT)"
    puts "  --model NAME          Model name (default: $LLM_MODEL)"
    puts "  --api-key KEY         API key (default: $LLM_API_KEY)"
    puts "  --help                Show this help"
    exit 0
  when "--"
    # End-of-options marker — everything after is a positional argument
    i += 1
    while i < args_iter.size
      sources << args_iter[i]
      i += 1
    end
    break
  else
    sources << args_iter[i]
    i += 1
  end
end

if sources.empty?
  puts "Usage: crystal run examples/describe_attachments.cr -- <url_or_path> [...]"
  puts "   or: crystal run examples/describe_attachments.cr -- --help"
  exit 1
end

config = Agent::Config.new(
  api_endpoint: endpoint,
  model: model,
  api_key: api_key,
  system_prompt: "You are a helpful assistant that describes attachments accurately and concisely."
)

agent = Agent.new(config)

puts "── agent-cr describe attachments ──"
puts "  endpoint: #{config.api_endpoint}"
puts "  model:    #{config.model}"
puts "  sources:"
sources.each { |s| puts "    - #{s}" }
puts

begin
  # Build the prompt describing the attachments to the model.
  prompt = String.build do |io|
    io << "Describe the following attachment"
    io << 's' if sources.size > 1
    io << ":"
    sources.each do |s|
      io << "\n- #{File.basename(s)}"
    end
  end

  response = agent.ask(prompt, attachments: sources)

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

agent.close
