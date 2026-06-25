require "json"
require "http/client"

class Agent
  # Raised when trying to use an Agent that has been closed.
  class ClosedError < Exception
    def initialize
      super("Agent has been closed")
    end
  end

  # A tool definition that matches the OpenAI tools API.
  class Tool
    getter function : FunctionDef

    def initialize(@function : FunctionDef)
    end

    class FunctionDef
      getter name : String
      getter description : String?
      getter parameters : Hash(String, JSON::Any)?

      def initialize(@name : String, @description : String? = nil, @parameters : Hash(String, JSON::Any)? = nil)
      end
    end
  end

  # Accumulates a tool call across multiple SSE deltas.
  # Must be a class (reference type) so the hash entry is mutated in place.
  private class ToolCallDelta
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
  # A nil messages array signals a reset request.
  private record Request,
    messages : Array(Message)?,
    tools : Array(Tool)?,
    response : Response

  getter config : Config
  getter history : Array(Message)

  @request_channel : Channel(Request)
  @fiber : Fiber
  @closed = false
  @registered_tools : Hash(String, NamedTuple(tool: Tool, callback: Hash(String, JSON::Any) -> String))

  # Persistent HTTP client for connection pooling.
  @http_client : HTTP::Client

  def initialize(@config : Config)
    @history = [] of Message
    @request_channel = Channel(Request).new
    @registered_tools = {} of String => NamedTuple(tool: Tool, callback: Hash(String, JSON::Any) -> String)
    @http_client = build_http_client
    @fiber = spawn { run_loop }
  end

  # Register a tool with a callback that will be called automatically when the
  # model requests this tool (when `auto_execute_tools` is true in config).
  #
  # The callback receives the parsed JSON arguments and returns a string result.
  # The tool definition is automatically included in all subsequent #ask calls.
  #
  # ```
  # agent.register_tool("get_weather", "Get the weather for a city",
  #   parameters: {
  #     "type"       => JSON::Any.new("object"),
  #     "properties" => JSON::Any.new({
  #       "city" => JSON::Any.new({"type" => JSON::Any.new("string")}),
  #     }),
  #     "required" => JSON::Any.new([] of JSON::Any),
  #   }
  # ) do |args|
  #   city = args["city"]?.try(&.as_s) || "unknown"
  #   "The weather in #{city} is sunny."
  # end
  # ```
  def register_tool(name : String, description : String? = nil, parameters : Hash(String, JSON::Any)? = nil, &block : Hash(String, JSON::Any) -> String) : Nil
    raise ClosedError.new if @closed
    raise ArgumentError.new("Tool name must not be empty") if name.empty?

    tool = Tool.new(Tool::FunctionDef.new(name: name, description: description, parameters: parameters))
    @registered_tools[name] = {tool: tool, callback: block}
  end

  # Close the agent, shutting down the background fiber.
  # Any pending or future #ask calls will get a closed-error response.
  # Safe to call multiple times.
  def close : Nil
    return if @closed

    @closed = true
    @request_channel.close
    @http_client.close
  end

  # Send a user message and return a Response immediately.
  # The actual HTTP call happens in a background fiber.
  #
  # If `auto_execute_tools` is true (default) and the model requests registered
  # tools, the agent will automatically execute them and re-ask the model in
  # the background. The final Response (after all tool loops) is returned.
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
            Message.new(role: Role::User, content_parts: parts)
          else
            Message.new(role: Role::User, content: content)
          end

    response = Response.new
    @request_channel.send(Request.new(build_messages([msg]), tools, response))
    @history << msg
    response
  rescue Channel::ClosedError
    raise ClosedError.new
  end

  # Send tool result messages and return a Response immediately.
  # Used to feed tool call results back to the model after it requests them.
  #
  # Raises Agent::ClosedError if the agent has been closed via #close.
  def ask(tool_results : Array(Message), tools : Array(Tool)? = nil) : Response
    raise ClosedError.new if @closed

    response = Response.new
    @request_channel.send(Request.new(build_messages(tool_results), tools, response))
    @history.concat(tool_results)
    response
  rescue Channel::ClosedError
    raise ClosedError.new
  end

  # Reset the conversation history back to the system prompt only.
  # Waits for any in-flight request to complete before clearing history.
  # Raises Agent::ClosedError if the agent has been closed.
  def reset : Nil
    raise ClosedError.new if @closed

    response = Response.new
    @request_channel.send(Request.new(nil, nil, response))
    response.join
  rescue Channel::ClosedError
    raise ClosedError.new
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  private def build_messages(msgs_to_append : Array(Message)) : Array(Message)
    msgs = [] of Message

    if (sys = @config.system_prompt) && !sys.empty?
      msgs << Message.new(role: Role::System, content: sys)
    end

    msgs.concat(@history)
    msgs.concat(msgs_to_append)
    msgs
  end

  private def run_loop : Nil
    loop do
      request = @request_channel.receive

      if request.messages.nil?
        # Reset request — clear history and signal completion.
        @history.clear
        request.response.finish(
          Message.new(role: Role::Assistant, content: "History cleared."),
          Usage.new,
        )
        next
      end

      process_request_loop(request)
    end
  rescue Channel::ClosedError
    # agent fiber exits on close — any fiber blocked in a send to the
    # request channel will also see ClosedError and raise to its caller.
  end

  # Process a request with automatic tool resolution.
  # When the model returns tool calls and auto_execute_tools is enabled,
  # registered tools are executed inline and the result is sent back to the
  # model — all within this fiber, without returning to the caller.
  private def process_request_loop(request : Request) : Nil
    response = request.response
    # ameba:disable Lint/NotNil
    messages = request.messages.not_nil!
    tools = request.tools

    loop do
      msg, usage, finish_reason = http_post_stream(messages, tools, response)

      # On error, http_post_stream already called response.finish/finish_with_error — stop.
      if response.error?
        break
      end

      # If no tool calls, or auto_execute is disabled, or no registered tools — done.
      no_tools = !msg.has_tool_calls? || !@config.auto_execute_tools || @registered_tools.empty?
      if no_tools
        response.finish(msg, usage, finish_reason: finish_reason)
        break
      end

      # ameba:disable Lint/NotNil
      tool_calls = msg.tool_calls.not_nil!
      results = execute_registered_tools(tool_calls)

      # If some tools had no registered handler, stop and let the caller handle it.
      if results.empty?
        response.finish(msg, usage, finish_reason: finish_reason)
        break
      end

      # Append tool results to history, then prepare next iteration.
      # We build messages from an empty append array because @history already
      # contains everything (including the results we just appended).
      @history.concat(results)
      messages = build_messages([] of Message)
    end
  end

  # Execute registered tool callbacks for the given tool calls.
  # Returns an array of tool result Messages, or an empty array if any
  # tool call has no registered handler.
  # If a callback raises, the error is caught and returned as a tool-result
  # message with an error description, so the agent fiber never dies.
  private def execute_registered_tools(tool_calls : Array(ToolCall)) : Array(Message)
    results = [] of Message

    tool_calls.each do |tc|
      entry = @registered_tools[tc.name]?
      if entry.nil?
        return [] of Message
      end

      # Parse the JSON arguments string into a hash for the callback.
      args_hash = begin
        parsed = JSON.parse(tc.arguments)
        parsed.as_h? || {} of String => JSON::Any
      rescue JSON::ParseException
        # Let the model know its arguments were malformed.
        results << Message.new(
          role: Role::Tool,
          content: "Error parsing arguments for tool '#{tc.name}': invalid JSON",
          tool_call_id: tc.id,
          name: tc.name,
        )
        next
      end

      result = begin
        entry[:callback].call(args_hash)
      rescue ex
        "Error executing tool '#{tc.name}': #{ex.message}"
      end

      results << Message.new(
        role: Role::Tool,
        content: result,
        tool_call_id: tc.id,
        name: tc.name,
      )
    end

    results
  end

  # Returns the combined tool list: per-request tools merged with registered tools.
  # Warns on name collisions (registered tools take precedence).
  private def combined_tools(tools : Array(Tool)?) : Array(Tool)?
    if @registered_tools.empty?
      tools
    else
      reg = @registered_tools.values.map(&.[:tool])

      if tools
        # Filter out per-request tools whose name collides with registered tools
        filtered = tools.reject { |t| @registered_tools.has_key?(t.function.name) }
        filtered + reg
      else
        reg
      end
    end
  end

  private def http_post_stream(
    messages : Array(Message),
    tools : Array(Tool)?,
    response : Response,
  ) : {Message, Usage, String?}
    all_tools = combined_tools(tools)
    body = build_request_body(messages, all_tools)
    full_path = @config.chat_path
    client = @http_client

    begin
      client.post(full_path, headers: HTTP::Headers.new, body: body.to_json) do |http_resp|
        unless http_resp.status.ok?
          raise ApiError.new(http_resp.status_code, "#{http_resp.status_code} #{http_resp.status_message}")
        end

        content_buffer, reasoning_buffer, tool_call_deltas, usage, finish_reason =
          process_sse_stream(http_resp.body_io, response)

        final_message = build_final_message(content_buffer, reasoning_buffer, tool_call_deltas)

        @history << final_message

        # Trim history: estimate one turn as 2 messages per user/assistant pair,
        # but also count tool messages which may appear between user and assistant.
        if (max = @config.max_history) && max > 0
          msg_count = @history.count { |m| m.role == Role::User || m.role == Role::Assistant }
          if msg_count > max * 2
            remove = @history.size - msg_count + max * 2
            remove = {remove, @history.size}.min
            remove = {remove, 0}.max
            @history.shift(remove)
          end
        end

        {final_message, usage, finish_reason}
      end
    rescue ex : ApiError
      response.finish_with_error(ex)
      {Message.new(role: Role::Assistant, content: "Agent error: #{ex.message}"), Usage.new, nil}
    rescue ex
      err = ConnectionError.new(ex.message || "Unknown error", cause: ex)
      response.finish_with_error(err)
      {Message.new(role: Role::Assistant, content: "Agent error: #{ex.message}"), Usage.new, nil}
    end
  end

  private def build_http_client : HTTP::Client
    uri = @config.parsed_uri
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

      # Inject extra headers
      if extra = @config.extra_headers
        extra.each { |k, v| req.headers[k] = v }
      end
    end

    client
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
      role: Role::Assistant,
      content: tool_calls && full_content.empty? ? nil : full_content,
      tool_calls: tool_calls,
      reasoning: reasoning_content.empty? ? nil : reasoning_content,
    )
  end

  private def process_sse_stream(
    body_io : IO,
    response : Response,
  ) : {String::Builder, String::Builder, Hash(Int32, ToolCallDelta), Usage, String?}
    tool_call_deltas = {} of Int32 => ToolCallDelta
    content_buffer = String::Builder.new
    reasoning_buffer = String::Builder.new
    usage = Usage.new
    finish_reason = nil

    body_io.each_line do |line|
      line = line.strip
      next if line.empty?
      next if line == "data: [DONE]"
      next unless line.starts_with?("data")

      # Extract JSON after "data:" (possibly with or without trailing space, per SSE spec)
      json_data = line[5..]
      json_data = json_data.lstrip(' ')

      json = begin
        JSON.parse(json_data)
      rescue JSON::ParseException
        next
      end
      parsed = json.as_h? || next

      usage = parse_usage(parsed, usage)
      finish_reason = process_deltas(parsed, response, content_buffer, reasoning_buffer, tool_call_deltas) || finish_reason
    end

    {content_buffer, reasoning_buffer, tool_call_deltas, usage, finish_reason}
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
  ) : String?
    finish_reason = nil

    choices = parsed["choices"]?.try(&.as_a?) || [] of JSON::Any
    choices.each do |choice|
      delta = choice["delta"]?.try(&.as_h?) || next

      if reason = choice["finish_reason"]?.try(&.as_s?)
        finish_reason = reason
      end

      if c = delta["content"]?.try(&.as_s?)
        content_buffer << c
        response.push_chunk(Response::Chunk.new(c, Response::ChunkKind::Content))
      end

      if rc = delta["reasoning_content"]?.try(&.as_s?)
        reasoning_buffer << rc
        response.push_chunk(Response::Chunk.new(rc, Response::ChunkKind::Reasoning))
      end

      process_tool_call_deltas(delta, tool_call_deltas, response)
    end

    finish_reason
  end

  private def process_tool_call_deltas(
    delta : Hash(String, JSON::Any),
    tool_call_deltas : Hash(Int32, ToolCallDelta),
    response : Response,
  ) : Nil
    tc_delta = delta["tool_calls"]?.try(&.as_a?) || return
    tc_delta.each do |tcd|
      idx = tcd["index"]?.try(&.as_i) || 0

      entry = tool_call_deltas[idx] ||= ToolCallDelta.new

      if id = tcd["id"]?
        entry.id = id.as_s
      end

      if fn = tcd["function"]?
        fn_h = fn.as_h
        if fn_h_name = fn_h["name"]?
          name_str = fn_h_name.as_s
          entry.name = name_str
          response.push_chunk(Response::Chunk.new(name_str, Response::ChunkKind::ToolCallName))
        end
        if fn_h_args = fn_h["arguments"]?
          entry.arguments += fn_h_args.as_s
          response.push_chunk(Response::Chunk.new(fn_h_args.as_s, Response::ChunkKind::ToolCallArgs))
        end
      end
    end
  end

  private def build_request_body(messages : Array(Message), tools : Array(Tool)?) : Hash(String, JSON::Any)
    body = {
      "model"    => JSON::Any.new(@config.model),
      "messages" => JSON::Any.new(messages.map(&.to_request_body).map { |h| JSON::Any.new(h) }),
      "stream"   => JSON::Any.new(@config.stream),
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
