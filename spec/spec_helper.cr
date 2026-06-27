require "spec"
require "../src/agent"

# Test handler that records before/after calls for EmbedContext.
class Agent::Spec::RecordingEmbedHandler < Agent::Handler
  property log : Array(String)

  def initialize(@log)
  end

  def handle(ctx : Agent::EmbedContext, next_proc) : Array(Float64)
    @log << "before"
    result = next_proc.call(ctx)
    @log << "after"
    result
  end
end

# Test handler that overrides the input and model on EmbedContext.
class Agent::Spec::OverrideEmbedHandler < Agent::Handler
  def handle(ctx : Agent::EmbedContext, next_proc) : Array(Float64)
    ctx.input = "overridden"
    ctx.model = "text-embedding-3-large"
    next_proc.call(ctx)
  end
end

# A minimal mock server that speaks the OpenAI streaming format and embeddings API.
# ameba:disable Metrics/CyclomaticComplexity
def with_mock_server(&)
  server = HTTP::Server.new do |ctx|
    if ctx.request.method == "POST" && ctx.request.path.includes?("/chat/completions")
      body = ctx.request.body.try(&.gets_to_end) || "{}"
      parsed = JSON.parse(body)

      ctx.response.content_type = "text/event-stream"
      ctx.response.status_code = 200

      messages = parsed["messages"].as_a
      last_user_msg = messages.reverse.find { |m| m["role"].as_s == "user" }
      reply = last_user_msg.try(&.["content"].as_s?) || "Hello"

      # Send reasoning content first (simulating Qwen/DeepSeek models)
      reasoning_text = "Reasoning..."
      reasoning_text.each_char do |ch|
        data = {
          choices: [{
            delta: {reasoning_content: ch.to_s},
            index: 0,
          }],
        }
        ctx.response.puts "data: #{data.to_json}"
        ctx.response.flush
      end

      reply.each_char do |ch|
        data = {
          choices: [{
            delta: {content: ch.to_s},
            index: 0,
          }],
        }
        ctx.response.puts "data: #{data.to_json}"
        ctx.response.flush
      end

      final = {
        choices: [{
          delta:         {} of String => JSON::Any,
          index:         0,
          finish_reason: "stop",
        }],
        usage: {
          prompt_tokens:     10,
          completion_tokens: reply.size,
          total_tokens:      10 + reply.size,
        },
      }
      ctx.response.puts "data: #{final.to_json}"
      ctx.response.puts "data: [DONE]"
      ctx.response.flush
      ctx.response.close
    elsif ctx.request.method == "POST" && ctx.request.path.includes?("/embeddings")
      body = ctx.request.body.try(&.gets_to_end) || "{}"
      parsed = JSON.parse(body)
      input = parsed["input"]?.try(&.as_s) || ""
      model = parsed["model"]?.try(&.as_s) || "text-embedding-3-small"

      ctx.response.content_type = "application/json"
      ctx.response.status_code = 200

      # Return a deterministic embedding vector based on input length
      dim = model.includes?("large") ? 3072 : 1536
      vector = Array.new(dim) { |i| ((input.size + i) % 100) / 100.0 }

      response = {
        object: "list",
        data:   [{
          object:    "embedding",
          index:     0,
          embedding: vector,
        }],
        model: model,
        usage: {
          prompt_tokens: input.size,
          total_tokens:  input.size,
        },
      }
      ctx.response.puts response.to_json
      ctx.response.flush
      ctx.response.close
    else
      ctx.response.status_code = 404
      ctx.response.puts "Not Found"
    end
  end

  address = server.bind_tcp(0)
  port = address.port
  ready = Channel(Nil).new
  spawn do
    ready.send(nil)
    server.listen
  end
  ready.receive

  begin
    yield port
  ensure
    server.close
  end
end
