require "./spec_helper"

# Agent integration tests using a local test server that mimics the OpenAI API.
# This avoids external HTTP calls and makes tests deterministic.

# A minimal mock server that speaks the OpenAI streaming format.
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

describe Agent do
  it "asks a question and gets a streamed response", tags: "remote" do
    with_mock_server do |port|
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:#{port}",
        model: "gpt-4o",
      )

      agent = Agent.new(config)
      resp = agent.ask("What is the capital of France?")

      chunks = [] of Agent::Response::Chunk
      resp.stream { |chunk| chunks << chunk }

      # Content should only include the actual content (reasoning is separate)
      resp.message.content.should eq("What is the capital of France?")
      resp.message.reasoning.should eq("Reasoning...")
      resp.metadata.total_tokens.should eq(10 + "What is the capital of France?".size)
      resp.finished?.should be_true
    end
  end

  it "tags reasoning chunks correctly", tags: "remote" do
    with_mock_server do |port|
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:#{port}",
      )

      agent = Agent.new(config)
      resp = agent.ask("Hello")

      reasoning_chunks = [] of String
      content_chunks = [] of String
      resp.stream do |chunk|
        if chunk.reasoning?
          reasoning_chunks << chunk.text
        else
          content_chunks << chunk.text
        end
      end

      reasoning_chunks.join.should eq("Reasoning...")
      content_chunks.join.should eq("Hello")
    end
  end

  it "maintains conversation history", tags: "remote" do
    with_mock_server do |port|
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:#{port}",
      )

      agent = Agent.new(config)
      resp1 = agent.ask("First")
      resp1.join

      resp2 = agent.ask("Second")
      resp2.join

      # History should contain both user messages and their responses
      agent.history.size.should eq(4)
      agent.history[0].role.should eq("user")
      agent.history[0].content.should eq("First")
      agent.history[2].role.should eq("user")
      agent.history[2].content.should eq("Second")
    end
  end

  it "resets history", tags: "remote" do
    with_mock_server do |port|
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:#{port}",
        system_prompt: "Be nice.",
      )

      agent = Agent.new(config)
      resp = agent.ask("Hello")
      resp.join

      agent.history.size.should eq(2) # user + assistant

      agent.reset
      agent.history.should be_empty
    end
  end

  it "supports multimodal input", tags: "remote" do
    with_mock_server do |port|
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:#{port}",
      )

      agent = Agent.new(config)
      resp = agent.ask(
        "What's in this image?",
        images: ["https://example.com/photo.jpg"]
      )
      resp.join

      # The generated message should have content_parts
      user_msg = agent.history[0]
      user_msg.content_parts.should_not be_nil
      user_msg.content_parts.try do |parts|
        parts.size.should eq(2)
        parts[0].text.should eq("What's in this image?")
        parts[1].image_url.should eq("https://example.com/photo.jpg")
      end
    end
  end

  it "supports tool calls in the request", tags: "remote" do
    with_mock_server do |port|
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:#{port}",
      )

      agent = Agent.new(config)

      tool = Agent::Tool.new(Agent::Tool::FunctionDef.new(
        name: "get_weather",
        description: "Get the weather",
        parameters: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "city" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          }),
        }
      ))

      resp = agent.ask("What's the weather in Paris?", tools: [tool])
      resp.join
      resp.message.content.should eq("What's the weather in Paris?")
      resp.message.reasoning.should eq("Reasoning...")
    end
  end

  it "handles API errors gracefully" do
    config = Agent::Config.new(
      api_key: "bad-key",
      api_endpoint: "http://localhost:1",
    )

    agent = Agent.new(config)
    resp = agent.ask("Hello")
    resp.join
    content = resp.message.content
    content.should_not be_nil
    content.to_s.should contain("error")
  end

  it "reports finish_reason from the API response" do
    with_mock_server do |port|
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:#{port}",
      )

      agent = Agent.new(config)
      resp = agent.ask("Hello")
      resp.join
      resp.finish_reason.should eq("stop")
    end
  end

  it "streams tool call argument chunks" do
    # Build JSON for tool call streaming test
    # arguments value must have its inner quotes escaped for valid JSON
    args_json = %({"city":"Paris"})
    delta1 = {"choices" => [{"delta" => {"tool_calls" => [{"index" => 0, "id" => "call_abc", "type" => "function", "function" => {"name" => "get_weather", "arguments" => ""}}]}, "index" => 0}]}.to_json
    delta2 = {"choices" => [{"delta" => {"tool_calls" => [{"index" => 0, "function" => {"arguments" => args_json}}]}, "index" => 0}]}.to_json
    delta3 = {"choices" => [{"delta" => {} of String => JSON::Any, "index" => 0, "finish_reason" => "tool_calls"}], "usage" => {"prompt_tokens" => 5, "completion_tokens" => 10, "total_tokens" => 15}}.to_json

    server = HTTP::Server.new do |ctx|
      if ctx.request.method == "POST" && ctx.request.path.includes?("/chat/completions")
        ctx.response.content_type = "text/event-stream"
        ctx.response.status_code = 200

        ctx.response.puts "data: #{delta1}"
        ctx.response.flush

        ctx.response.puts "data: #{delta2}"
        ctx.response.flush

        ctx.response.puts "data: #{delta3}"
        ctx.response.puts "data: [DONE]"
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
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:#{port}",
      )

      agent = Agent.new(config)
      resp = agent.ask("What's the weather?")

      tool_chunks = [] of String
      resp.stream do |chunk|
        if chunk.kind == Agent::Response::ChunkKind::ToolCallArgs
          tool_chunks << chunk.text
        end
      end

      tool_chunks.join.should eq(%({"city":"Paris"}))
      resp.message.tool_calls.should_not be_nil
      resp.message.tool_calls.not_nil!.size.should eq(1)
      resp.message.tool_calls.not_nil![0].name.should eq("get_weather")
      resp.message.tool_calls.not_nil![0].id.should eq("call_abc")
      resp.message.tool_calls.not_nil![0].arguments.should eq(%({"city":"Paris"}))
      resp.finish_reason.should eq("tool_calls")
    ensure
      server.close
    end
  end

  describe "#close" do
    it "prevents further #ask calls", tags: "remote" do
      with_mock_server do |port|
        config = Agent::Config.new(
          api_key: "test-key",
          api_endpoint: "http://localhost:#{port}",
        )

        agent = Agent.new(config)
        resp = agent.ask("Hello")
        resp.join

        agent.close
        expect_raises(Agent::ClosedError) do
          agent.ask("Another")
        end
      end
    end

    it "prevents #reset", tags: "remote" do
      with_mock_server do |port|
        config = Agent::Config.new(
          api_key: "test-key",
          api_endpoint: "http://localhost:#{port}",
        )

        agent = Agent.new(config)
        agent.close
        expect_raises(Agent::ClosedError) do
          agent.reset
        end
      end
    end

    it "is safe to call multiple times", tags: "remote" do
      agent = Agent.new(Agent::Config.new)
      agent.close
      agent.close # should not raise
    end

    it "finishes an in-flight request normally before closing", tags: "remote" do
      with_mock_server do |port|
        config = Agent::Config.new(
          api_key: "test-key",
          api_endpoint: "http://localhost:#{port}",
        )

        agent = Agent.new(config)
        resp = agent.ask("Hello")
        # The fiber is already processing this request.
        # Close only prevents *future* requests.
        agent.close

        # The in-flight response should still complete.
        resp.join
        resp.message.content.should_not be_nil
        resp.finished?.should be_true
      end
    end
  end
end
