require "json"
require "http/client"
require "uri"

class Agent
  # Raised when trying to use an Agent that has been closed.
  class ClosedError < Exception
    def initialize
      super("Agent has been closed")
    end
  end

  # A tool definition that matches the OpenAI tools API.
  class Tool
    include JSON::Serializable

    getter function : FunctionDef

    def initialize(@function : FunctionDef)
    end

    class FunctionDef
      include JSON::Serializable

      getter name : String
      getter description : String?
      getter parameters : Hash(String, JSON::Any)?

      def initialize(@name : String, @description : String? = nil, @parameters : Hash(String, JSON::Any)? = nil)
      end
    end
  end

  # Accumulates a tool call across multiple SSE deltas.
  private struct ToolCallDelta
    property id : String
    property name : String
    property arguments : String

    def initialize
      @id = ""
      @name = ""
      @arguments = ""
    end
  end

  # Internal request sent from #ask to the processing fiber.
  private record Request,
    messages : Array(Message),
    tools : Array(Tool)?,
    response : Response

  getter config : Config
  getter history : Array(Message)

  @request_channel : Channel(Request)
  @fiber : Fiber
  @closed = false

  def initialize(@config : Config)
    @history = [] of Message
    @request_channel = Channel(Request).new
    @fiber = spawn { run_loop }
  end

  # Close the agent, shutting down the background fiber.
  # Any pending or future #ask calls will get a closed-error response.
  # Safe to call multiple times.
  def close : Nil
    return if @closed

    @closed = true
    @request_channel.close
  end

  # Send a user message and return a Response immediately.
  # The actual HTTP call happens in a background fiber.
  #
  # ```
  # resp = agent.ask("What is the capital of France?")
  # resp.stream { |chunk| print chunk }
  # puts resp.message.content
  # ```
  #
  # Raises Agent::ClosedError if the agent has been closed via #close.
  def ask(content : String, images : Array(String)? = nil, tools : Array(Tool)? = nil) : Response
    raise ClosedError.new if @closed

    msg = if imgs = images
            parts = [ContentPart.new(text: content)] + imgs.map { |url| ContentPart.new(image_url: url) }
            Message.new(role: "user", content_parts: parts)
          else
            Message.new(role: "user", content: content)
          end

    @history << msg
    response = Response.new
    @request_channel.send(Request.new(build_messages, tools, response))
    response
  rescue Channel::ClosedError
    raise ClosedError.new
  end

  # Reset the conversation history back to the system prompt only.
  # Raises Agent::ClosedError if the agent has been closed.
  def reset : Nil
    raise ClosedError.new if @closed
    @history.clear
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  private def build_messages : Array(Message)
    msgs = [] of Message

    if (sys = @config.system_prompt) && !sys.empty?
      msgs << Message.new(role: "system", content: sys)
    end

    msgs.concat(@history)
    msgs
  end

  private def run_loop : Nil
    loop do
      request = @request_channel.receive
      begin
        process_request(request)
      rescue ex
        request.response.finish(
          Message.new(role: "assistant", content: "Agent error: #{ex.message}"),
          Usage.new
        )
      end
    end
  rescue Channel::ClosedError
    # agent fiber exits on close — any fiber blocked in a send to the
    # request channel will also see ClosedError and raise to its caller.
  end

  private def process_request(req : Request) : Nil
    http_post_stream(req.messages, req.tools, req.response)
  end

  private def http_post_stream(
    messages : Array(Message),
    tools : Array(Tool)?,
    response : Response,
  ) : Nil
    body = build_request_body(messages, tools)
    client = build_http_client
    full_path = api_chat_path

    begin
      client.post(full_path, headers: HTTP::Headers.new, body: body.to_json) do |http_resp|
        unless http_resp.status.ok?
          raise "#{http_resp.status_code} #{http_resp.status_message}"
        end

        content_buffer, reasoning_buffer, tool_call_deltas, usage =
          process_sse_stream(http_resp.body_io, response)

        final_message = build_final_message(content_buffer, reasoning_buffer, tool_call_deltas)

        @history << final_message

        # Trim history to max_history pairs (2 messages per turn: user + assistant)
        if (max = @config.max_history) && max > 0
          if @history.size > max * 2
            remove = @history.size - max * 2
            @history.shift(remove)
          end
        end

        response.finish(final_message, usage)
      end
    rescue ex
      error_msg = Message.new(role: "assistant", content: "Agent error: #{ex.message}")
      response.finish(error_msg, Usage.new)
    ensure
      client.close
    end
  end

  private def build_http_client : HTTP::Client
    uri = URI.parse(@config.api_endpoint)
    client = HTTP::Client.new(uri)

    if (rt = @config.read_timeout) && rt > Time::Span.zero
      client.read_timeout = rt
    end
    if (ct = @config.connect_timeout) && ct > Time::Span.zero
      client.connect_timeout = ct
    end

    client.before_request do |req|
      if key = @config.api_key
        req.headers["Authorization"] = "Bearer #{key}"
      end
      req.headers["Content-Type"] = "application/json"
      req.headers["Accept"] = "text/event-stream"
    end

    client
  end

  private def api_chat_path : String
    uri = URI.parse(@config.api_endpoint)
    base_path = uri.path.empty? || uri.path == "/" ? "" : uri.path.gsub(/\/+$/, "")
    "#{base_path}/chat/completions"
  end

  private def build_final_message(
    content_buffer : String::Builder,
    reasoning_buffer : String::Builder,
    tool_call_deltas : Hash(Int32, ToolCallDelta),
  ) : Message
    full_content = content_buffer.to_s
    reasoning_content = reasoning_buffer.to_s

    tool_calls = if tool_call_deltas.empty?
                   nil
                 else
                   tool_call_deltas.map do |_idx, delta|
                     ToolCall.new(id: delta.id, name: delta.name, arguments: delta.arguments)
                   end
                 end

    Message.new(
      role: "assistant",
      content: tool_calls && full_content.empty? ? nil : full_content,
      tool_calls: tool_calls,
      reasoning: reasoning_content.empty? ? nil : reasoning_content,
    )
  end

  private def process_sse_stream(
    body_io : IO,
    response : Response,
  ) : {String::Builder, String::Builder, Hash(Int32, ToolCallDelta), Usage}
    tool_call_deltas = {} of Int32 => ToolCallDelta
    content_buffer = String::Builder.new
    reasoning_buffer = String::Builder.new
    usage = Usage.new

    body_io.each_line do |line|
      line = line.strip
      next if line.empty?
      next if line == "data: [DONE]"
      next unless line.starts_with?("data: ")

      json_data = line[6..]

      json = begin
        JSON.parse(json_data)
      rescue JSON::ParseException
        next
      end
      parsed = json.as_h? || next

      usage = parse_usage(parsed, usage)
      process_deltas(parsed, response, content_buffer, reasoning_buffer, tool_call_deltas)
    end

    {content_buffer, reasoning_buffer, tool_call_deltas, usage}
  end

  private def parse_usage(parsed : Hash(String, JSON::Any), prev_usage : Usage) : Usage
    if usage_data = parsed["usage"]?
      u = usage_data.as_h
      Usage.new(
        prompt_tokens: u["prompt_tokens"]?.try(&.as_i),
        completion_tokens: u["completion_tokens"]?.try(&.as_i),
        total_tokens: u["total_tokens"]?.try(&.as_i)
      )
    elsif timings = parsed["timings"]?
      timings_h = timings.as_h
      prompt_n = timings_h["prompt_n"]?.try(&.as_i)
      predicted_n = timings_h["predicted_n"]?.try(&.as_i)
      Usage.new(
        prompt_tokens: prev_usage.prompt_tokens || prompt_n,
        completion_tokens: prev_usage.completion_tokens || predicted_n,
        total_tokens: prev_usage.total_tokens || (prompt_n && predicted_n ? prompt_n + predicted_n : nil)
      )
    else
      prev_usage
    end
  end

  private def process_deltas(
    parsed : Hash(String, JSON::Any),
    response : Response,
    content_buffer : String::Builder,
    reasoning_buffer : String::Builder,
    tool_call_deltas : Hash(Int32, ToolCallDelta),
  ) : Nil
    choices = parsed["choices"]?.try(&.as_a?) || [] of JSON::Any
    choices.each do |choice|
      delta = choice["delta"]?.try(&.as_h?) || next

      if c = delta["content"]?.try(&.as_s?)
        content_buffer << c
        response.push_chunk(Response::Chunk.new(c, Response::ChunkKind::Content))
      end

      if rc = delta["reasoning_content"]?.try(&.as_s?)
        reasoning_buffer << rc
        response.push_chunk(Response::Chunk.new(rc, Response::ChunkKind::Reasoning))
      end

      process_tool_call_deltas(delta, tool_call_deltas)
    end
  end

  private def process_tool_call_deltas(
    delta : Hash(String, JSON::Any),
    tool_call_deltas : Hash(Int32, ToolCallDelta),
  ) : Nil
    tc_delta = delta["tool_calls"]?.try(&.as_a?) || return
    tc_delta.each do |tcd|
      idx = tcd["index"]?.try(&.as_i) || 0

      entry = tool_call_deltas[idx] ||= ToolCallDelta.new

      if id = tcd["id"]?
        entry.id += id.as_s
      end

      if fn = tcd["function"]?
        fn_h = fn.as_h
        if fn_h_name = fn_h["name"]?
          entry.name += fn_h_name.as_s
        end
        if fn_h_args = fn_h["arguments"]?
          entry.arguments += fn_h_args.as_s
        end
      end
    end
  end

  private def build_request_body(messages : Array(Message), tools : Array(Tool)?) : Hash(String, JSON::Any)
    body = {
      "model"    => JSON::Any.new(@config.model),
      "messages" => JSON::Any.new(messages.map(&.to_request_body).map { |h| JSON::Any.new(h) }),
      "stream"   => JSON::Any.new(true),
    }

    if mt = @config.max_tokens
      body["max_tokens"] = JSON::Any.new(mt.to_i64)
    end

    if t = @config.temperature
      body["temperature"] = JSON::Any.new(t)
    end

    if ts = tools
      body["tools"] = JSON::Any.new(ts.map do |tool_def|
        fd = tool_def.function
        JSON::Any.new({
          "type"     => JSON::Any.new("function"),
          "function" => JSON::Any.new({
            "name"        => JSON::Any.new(fd.name),
            "description" => JSON::Any.new(fd.description || ""),
            "parameters"  => JSON::Any.new(fd.parameters || {} of String => JSON::Any),
          }),
        })
      end)
    end

    body
  end
end
