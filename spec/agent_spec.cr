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
  it "asks a question and gets a streamed response" do
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

  it "tags reasoning chunks correctly" do
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

  it "maintains conversation history" do
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
      agent.history[0].role.should eq(Agent::Role::User)
      agent.history[0].content.should eq("First")
      agent.history[2].role.should eq(Agent::Role::User)
      agent.history[2].content.should eq("Second")
    end
  end

  it "resets history" do
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

  it "supports multimodal input" do
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

  it "supports tool calls in the request" do
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
    resp.error?.should be_true
    resp.error.should be_a(Agent::ConnectionError)
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
      tcs = resp.message.tool_calls
      tcs.should_not be_nil
      # ameba:disable Lint/NotNil
      tcs = tcs.not_nil!
      tcs.size.should eq(1)
      tcs[0].name.should eq("get_weather")
      tcs[0].id.should eq("call_abc")
      tcs[0].arguments.should eq(%({"city":"Paris"}))
      resp.finish_reason.should eq("tool_calls")
    ensure
      server.close
    end
  end

  it "auto-resolves registered tools" do
    # A mock server that:
    #  1st request -> returns a tool call (finish_reason: tool_calls)
    #  2nd request -> returns a normal text response (finish_reason: stop)
    call_count = 0
    server = HTTP::Server.new do |ctx|
      if ctx.request.method == "POST" && ctx.request.path.includes?("/chat/completions")
        call_count += 1
        ctx.response.content_type = "text/event-stream"
        ctx.response.status_code = 200

        if call_count == 1
          # Return tool call
          delta1 = {"choices" => [{"delta" => {"tool_calls" => [{"index" => 0, "id" => "call_001", "type" => "function", "function" => {"name" => "test_tool", "arguments" => ""}}]}, "index" => 0}]}.to_json
          delta2 = {"choices" => [{"delta" => {"tool_calls" => [{"index" => 0, "function" => {"arguments" => %({"input":"world"})}}]}, "index" => 0}]}.to_json
          final = {"choices" => [{"delta" => {} of String => JSON::Any, "index" => 0, "finish_reason" => "tool_calls"}], "usage" => {"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}}.to_json
          ctx.response.puts "data: #{delta1}"
          ctx.response.flush
          ctx.response.puts "data: #{delta2}"
          ctx.response.flush
          ctx.response.puts "data: #{final}"
          ctx.response.puts "data: [DONE]"
          ctx.response.flush
        else
          # Return normal text (tool result was included in the second request)
          reply = "Tool result received: processed"
          reply.each_char do |ch|
            data = {"choices" => [{"delta" => {"content" => ch.to_s}, "index" => 0}]}.to_json
            ctx.response.puts "data: #{data}"
            ctx.response.flush
          end
          final = {"choices" => [{"delta" => {} of String => JSON::Any, "index" => 0, "finish_reason" => "stop"}], "usage" => {"prompt_tokens" => 20, "completion_tokens" => reply.size, "total_tokens" => 20 + reply.size}}.to_json
          ctx.response.puts "data: #{final}"
          ctx.response.puts "data: [DONE]"
          ctx.response.flush
        end
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
        auto_execute_tools: true,
      )

      agent = Agent.new(config)

      # Register the tool that should be auto-resolved
      tool_result = ""
      agent.register_tool("test_tool", "A test tool",
        parameters: Agent::JSONConverter.from({
          type:       "object",
          properties: {
            input: {type: "string"},
          },
          required: ["input"],
        })
      ) do |args|
        tool_result = args["input"]?.try(&.as_s) || ""
        "Processed: #{tool_result}"
      end

      resp = agent.ask("Run the tool")

      # Stream the response (should be the final text after tool resolution)
      content = [] of String
      resp.stream { |chunk| content << chunk.text if chunk.content? }

      # Verify the auto-resolve loop ran
      resp.message.content.should eq("Tool result received: processed")
      tool_result.should eq("world")

      # Verify the history includes: user, assistant(tool_calls), tool, assistant(final)
      agent.history.size.should eq(4)
      agent.history[0].role.should eq(Agent::Role::User)
      agent.history[1].role.should eq(Agent::Role::Assistant)
      agent.history[1].has_tool_calls?.should be_true
      agent.history[2].role.should eq(Agent::Role::Tool)
      agent.history[3].role.should eq(Agent::Role::Assistant)
      agent.history[3].content.should eq("Tool result received: processed")
    ensure
      server.close
    end
  end

  it "reports error when auto-resolve tool callback raises" do
    call_count = 0
    server = HTTP::Server.new do |ctx|
      if ctx.request.method == "POST" && ctx.request.path.includes?("/chat/completions")
        call_count += 1
        ctx.response.content_type = "text/event-stream"
        ctx.response.status_code = 200

        if call_count == 1
          delta1 = {"choices" => [{"delta" => {"tool_calls" => [{"index" => 0, "id" => "call_001", "type" => "function", "function" => {"name" => "failing_tool", "arguments" => ""}}]}, "index" => 0}]}.to_json
          delta2 = {"choices" => [{"delta" => {"tool_calls" => [{"index" => 0, "function" => {"arguments" => %({})}}]}, "index" => 0}]}.to_json
          final = {"choices" => [{"delta" => {} of String => JSON::Any, "index" => 0, "finish_reason" => "tool_calls"}], "usage" => {"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}}.to_json
          ctx.response.puts "data: #{delta1}"
          ctx.response.flush
          ctx.response.puts "data: #{delta2}"
          ctx.response.flush
          ctx.response.puts "data: #{final}"
          ctx.response.puts "data: [DONE]"
          ctx.response.flush
        else
          # Second request: verify the tool error message is present in history
          reply = "error noted"
          reply.each_char do |ch|
            data = {"choices" => [{"delta" => {"content" => ch.to_s}, "index" => 0}]}.to_json
            ctx.response.puts "data: #{data}"
            ctx.response.flush
          end
          final = {"choices" => [{"delta" => {} of String => JSON::Any, "index" => 0, "finish_reason" => "stop"}], "usage" => {"prompt_tokens" => 20, "completion_tokens" => reply.size, "total_tokens" => 20 + reply.size}}.to_json
          ctx.response.puts "data: #{final}"
          ctx.response.puts "data: [DONE]"
          ctx.response.flush
        end
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
        auto_execute_tools: true,
      )

      agent = Agent.new(config)

      # Register a tool that raises
      agent.register_tool("failing_tool", "A tool that always fails",
        parameters: Agent::JSONConverter.from({
          type:       "object",
          properties: {} of String => String,
          required:   [] of String,
        })
      ) do |_args|
        raise "Intentional failure"
      end

      resp = agent.ask("Test failing tool")
      resp.join

      # The tool error should be captured as a tool result message with error text
      tool_msg = agent.history[2]
      tool_msg.role.should eq(Agent::Role::Tool)
      tool_msg.content.should_not be_nil
      tool_msg.content.to_s.should contain("Error executing tool 'failing_tool'")
      tool_msg.content.to_s.should contain("Intentional failure")
    ensure
      server.close
    end
  end

  it "handles register_tool with no auto_execute" do
    with_mock_server do |port|
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:#{port}",
        auto_execute_tools: false,
      )

      agent = Agent.new(config)

      called = false
      agent.register_tool("echo", "Echo input",
        parameters: Agent::JSONConverter.from({
          type:       "object",
          properties: {
            text: {type: "string"},
          },
          required: ["text"],
        })
      ) do |args|
        called = true
        args["text"]?.try(&.as_s) || ""
      end

      # When auto_execute_tools is false, the tool should be included in the request
      # but the callback won't be called automatically.
      resp = agent.ask("Hello")
      resp.join
      called.should be_false
    end
  end

  it "trims history with max_history" do
    call_count = 0
    server = HTTP::Server.new do |ctx|
      if ctx.request.method == "POST" && ctx.request.path.includes?("/chat/completions")
        call_count += 1
        ctx.response.content_type = "text/event-stream"
        ctx.response.status_code = 200

        reply = "Response #{call_count}"
        reply.each_char do |ch|
          data = {"choices" => [{"delta" => {"content" => ch.to_s}, "index" => 0}]}.to_json
          ctx.response.puts "data: #{data}"
          ctx.response.flush
        end
        final = {"choices" => [{"delta" => {} of String => JSON::Any, "index" => 0, "finish_reason" => "stop"}], "usage" => {"prompt_tokens" => 10, "completion_tokens" => reply.size, "total_tokens" => 10 + reply.size}}.to_json
        ctx.response.puts "data: #{final}"
        ctx.response.puts "data: [DONE]"
        ctx.response.flush
        ctx.response.close
      else
        ctx.response.status_code = 404
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
        max_history: 1, # Keep at most 1 user+assistant pair
      )

      agent = Agent.new(config)
      agent.ask("First").join  # history: user, assistant (2 msgs)
      agent.ask("Second").join # history: user, assistant, user, assistant (4 msgs) -> trimmed to 2
      agent.ask("Third").join  # trimmed again

      # With max_history=1, only the last user+assistant pair should survive
      agent.history.size.should eq(2)
      agent.history[0].role.should eq(Agent::Role::User)
      agent.history[0].content.should eq("Third")
      agent.history[1].role.should eq(Agent::Role::Assistant)
      agent.history[1].content.should eq("Response 3")
    ensure
      server.close
    end
  end

  it "produces structured error on API non-2xx" do
    server = HTTP::Server.new do |ctx|
      if ctx.request.method == "POST" && ctx.request.path.includes?("/chat/completions")
        ctx.response.status_code = 401
        ctx.response.puts "Unauthorized"
        ctx.response.close
      else
        ctx.response.status_code = 404
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
        api_key: "bad-key",
        api_endpoint: "http://localhost:#{port}",
      )

      agent = Agent.new(config)
      resp = agent.ask("Hello")
      resp.join
      resp.error?.should be_true
      resp.error.should be_a(Agent::ApiError)
      resp.error.as(Agent::ApiError).status_code.should eq(401)
    ensure
      server.close
    end
  end

  describe "#trim_history!" do
    it "trims history without orphaning tool messages" do
      # A more complex mock server that:
      #   1st ask -> returns tool calls
      #   2nd ask -> returns plain text (tool results fed back)
      #   3rd ask -> triggers trimming (more than max_history turns)
      call_count = 0
      server = HTTP::Server.new do |ctx|
        if ctx.request.method == "POST" && ctx.request.path.includes?("/chat/completions")
          call_count += 1
          ctx.response.content_type = "text/event-stream"
          ctx.response.status_code = 200

          if call_count <= 2
            # First two calls: return tool calls
            delta1 = {"choices" => [{"delta" => {"tool_calls" => [{"index" => 0, "id" => "call_001", "type" => "function", "function" => {"name" => "test_tool", "arguments" => ""}}]}, "index" => 0}]}.to_json
            delta2 = {"choices" => [{"delta" => {"tool_calls" => [{"index" => 0, "function" => {"arguments" => %({"input":"test"})}}]}, "index" => 0}]}.to_json
            final = {"choices" => [{"delta" => {} of String => JSON::Any, "index" => 0, "finish_reason" => "tool_calls"}], "usage" => {"prompt_tokens" => 5, "completion_tokens" => 5, "total_tokens" => 10}}.to_json
            ctx.response.puts "data: #{delta1}"
            ctx.response.flush
            ctx.response.puts "data: #{delta2}"
            ctx.response.flush
            ctx.response.puts "data: #{final}"
            ctx.response.puts "data: [DONE]"
            ctx.response.flush
          else
            # Third call: return plain text (triggers trim after this)
            reply = "final"
            reply.each_char do |ch|
              data = {"choices" => [{"delta" => {"content" => ch.to_s}, "index" => 0}]}.to_json
              ctx.response.puts "data: #{data}"
              ctx.response.flush
            end
            final = {"choices" => [{"delta" => {} of String => JSON::Any, "index" => 0, "finish_reason" => "stop"}], "usage" => {"prompt_tokens" => 10, "completion_tokens" => reply.size, "total_tokens" => 10 + reply.size}}.to_json
            ctx.response.puts "data: #{final}"
            ctx.response.puts "data: [DONE]"
            ctx.response.flush
          end
          ctx.response.close
        else
          ctx.response.status_code = 404
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
          max_history: 1, # keep only 1 user+assistant pair
          auto_execute_tools: true,
        )

        agent = Agent.new(config)

        # Register the tool so auto-resolve kicks in
        agent.register_tool("test_tool", "A test tool",
          parameters: Agent::JSONConverter.from({
            type:       "object",
            properties: {
              input: {type: "string"},
            },
            required: ["input"],
          })
        ) do |args|
          "processed: #{args["input"]?.try(&.as_s)}"
        end

        # Round 1: user->tool_call->tool_result->final
        resp1 = agent.ask("First")
        resp1.join
        # History: user, assistant(tool_calls), tool, assistant(final) = 4

        # Round 2: another tool-call turn
        resp2 = agent.ask("Second")
        resp2.join
        # History grows: old 4 + new 4 = 8, then trimmed to max_history*2=2
        # The trim must not orphan the tool messages from the surviving turn

        # With max_history=1, only 2 user+assistant should survive
        # The survivor must be a complete turn with no orphaned tool messages
        agent.history.size.should eq(2)
        agent.history[0].role.should eq(Agent::Role::User)
        agent.history[0].content.should eq("Second")
        agent.history[1].role.should eq(Agent::Role::Assistant)
        agent.history[1].content.should eq("final")
        agent.history[1].has_tool_calls?.should be_false
      ensure
        server.close
      end
    end
  end

  it "handles concurrent #ask from multiple fibers" do
    with_mock_server do |port|
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:#{port}",
      )

      agent = Agent.new(config)
      responses = [] of Agent::Response
      fibers = 5
      channel = Channel(Nil).new(fibers)

      fibers.times do |i|
        spawn do
          resp = agent.ask("Concurrent #{i}")
          resp.join
          responses << resp
          channel.send(nil)
        end
      end

      # Wait for all fibers to complete
      fibers.times { channel.receive }

      responses.size.should eq(fibers)
      responses.each do |resp|
        resp.message.content.should_not be_nil
        resp.finished?.should be_true
      end

      # History should have 2*fibers entries (user + assistant per request)
      agent.history.size.should eq(fibers * 2)
    end
  end

  it "cancels an in-flight response" do
    with_mock_server do |port|
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:#{port}",
      )

      agent = Agent.new(config)
      resp = agent.ask("Hello")

      # Cancel immediately — the SSE stream should stop early
      resp.cancel

      # The response should still complete (finish_with_error or finish)
      resp.join
      resp.finished?.should be_true
    end
  end

  describe "#close" do
    it "prevents further #ask calls" do
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

    it "prevents #reset" do
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

    it "is safe to call multiple times" do
      agent = Agent.new(Agent::Config.new)
      agent.close
      agent.close # should not raise
    end

    it "finishes an in-flight request normally before closing" do
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
