require "json"
require "http/client"

class Agent
  # Raised when trying to use an Agent that has been closed.
  class ClosedError < Error
    def initialize
      super("Agent has been closed")
    end
  end

  # Internal request types sent to the processing fiber.
  private record AskRequest, new_messages : Array(Message), tools : Array(Tool)?, response : Response
  private record ResetRequest, response : Response
  private record RegisterToolRequest,
    name : String,
    tool : Tool,
    callback : (Hash(String, JSON::Any) -> String)?,
    enabled : Bool
  private record EnableToolRequest, name : String, enabled : Bool, response : Response
  private record LoadHistoryRequest, messages : Array(Message), response : Response

  private alias Request = AskRequest | ResetRequest | RegisterToolRequest | EnableToolRequest | LoadHistoryRequest

  getter config : Config
  getter history : Array(Message)
  getter session_id : String
  getter cache_key : String

  @request_channel : Channel(Request)
  @fiber : Fiber
  @closed = false
  @registered_tools : Hash(String, NamedTuple(tool: Tool, callback: (Hash(String, JSON::Any) -> String)?, enabled: Bool))

  # Persistent HTTP client for connection pooling across requests.
  @http_client : HTTP::Client
  # The provider handles all wire-format concerns.
  @provider : Provider::Base

  def initialize(@config : Config, provider : Provider::Base? = nil)
    @session_id = Random::Secure.hex(16)
    @cache_key = @config.prompt_cache_key || "agent-cr:#{@session_id}"
    @history = [] of Message
    @request_channel = Channel(Request).new
    @registered_tools = {} of String => NamedTuple(tool: Tool, callback: (Hash(String, JSON::Any) -> String)?, enabled: Bool)
    @provider = provider || Provider::OpenAI.new(@config, @cache_key)
    @http_client = build_http_client
    @fiber = spawn { run_loop }
  end

  # Internal: create an Agent with a pre-determined session_id and cache_key.
  # Used by `self.load` to restore a previous session's cache affinity.
  private def initialize(@config : Config, @session_id : String, @cache_key : String, provider : Provider::Base? = nil)
    @history = [] of Message
    @request_channel = Channel(Request).new
    @registered_tools = {} of String => NamedTuple(tool: Tool, callback: (Hash(String, JSON::Any) -> String)?, enabled: Bool)
    @provider = provider || Provider::OpenAI.new(@config, @cache_key)
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
  def register_tool(name : String, description : String? = nil, parameters : Hash(String, JSON::Any)? = nil, enabled : Bool = true, &block : Hash(String, JSON::Any) -> String) : Nil
    raise ClosedError.new if @closed
    raise ArgumentError.new("Tool name must not be empty") if name.empty?

    tool = Tool.new(Tool::FunctionDef.new(name: name, description: description, parameters: parameters))
    entry = {tool: tool, callback: block, enabled: enabled}

    if Fiber.current == @fiber
      # Already inside the agent fiber — mutate directly to avoid deadlock.
      @registered_tools[name] = entry
    else
      # From another fiber — route through the request channel for ordering.
      @request_channel.send(RegisterToolRequest.new(name, tool, block, enabled))
    end
  end

  # Enable a previously registered tool, making it available to the model.
  # Returns `false` if no tool with that name is registered.
  # Safe to call from any fiber.
  def enable_tool(name : String) : Bool
    raise ClosedError.new if @closed

    if Fiber.current == @fiber
      return false unless @registered_tools.has_key?(name)
      @registered_tools[name] = @registered_tools[name].merge({enabled: true})
      true
    else
      response = Response.new
      @request_channel.send(EnableToolRequest.new(name, true, response))
      response.join
      true
    end
  end

  # Disable a registered tool, hiding it from the model without unregistering it.
  # Returns `false` if no tool with that name is registered.
  # Safe to call from any fiber.
  def disable_tool(name : String) : Bool
    raise ClosedError.new if @closed

    if Fiber.current == @fiber
      return false unless @registered_tools.has_key?(name)
      @registered_tools[name] = @registered_tools[name].merge({enabled: false})
      true
    else
      response = Response.new
      @request_channel.send(EnableToolRequest.new(name, false, response))
      response.join
      true
    end
  end

  # Returns the names of all currently enabled tools.
  def enabled_tools : Array(String)
    @registered_tools.select { |_, v| v[:enabled] }.keys
  end

  # Close the agent, shutting down the background fiber.
  # Any pending or future #ask calls will get a closed-error response.
  # Safe to call multiple times.
  def close : Nil
    return if @closed

    @closed = true
    @request_channel.close
    @http_client.close
    @provider.close
  end

  # Send a user message and return a Response immediately.
  # The actual HTTP call happens in a background fiber.
  #
  # If `auto_execute_tools` is true (default) and the model requests registered
  # tools, the agent will automatically execute them and re-ask the model in
  # the background. The final Response (after all tool loops) is returned.
  #
  # Pass `attachments` as an array of file paths, URLs, or data URIs.
  # Local files are read and auto-typed by MIME (image → image_url,
  # text → inline text, audio → input_audio, other → file).
  #
  # ```
  # resp = agent.ask("What is in this image?", attachments: ["photo.jpg"])
  # resp.stream { |chunk| print chunk }
  # puts resp.message.content
  # ```
  #
  # Raises Agent::ClosedError if the agent has been closed via #close.
  def ask(content : String, attachments : Array(String)? = nil, tools : Array(Tool)? = nil) : Response
    raise ClosedError.new if @closed

    msg = if atts = attachments
            parts = [ContentPart.new(type: :text, text: content)] + atts.map { |path| ContentPart.from_path(path) }
            Message.new(role: Role::User, content_parts: parts)
          else
            Message.new(role: Role::User, content: content)
          end

    response = Response.new
    @request_channel.send(AskRequest.new([msg], tools, response))
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
    @request_channel.send(AskRequest.new(tool_results, tools, response))
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
    @request_channel.send(ResetRequest.new(response))
    response.join
  rescue Channel::ClosedError
    raise ClosedError.new
  end

  # Restore the full conversation history.
  # This replaces the current history with the given messages (e.g. from a
  # previous `#dump`). The system prompt is NOT included — `build_messages`
  # prepends it from Config as usual.
  #
  # Safe to call after a previous #ask has completed. Waits for the fiber to
  # acknowledge the replacement before returning.
  #
  # Raises Agent::ClosedError if the agent has been closed.
  def load_history(messages : Array(Message)) : Nil
    raise ClosedError.new if @closed

    response = Response.new
    @request_channel.send(LoadHistoryRequest.new(messages, response))
    response.join
  rescue Channel::ClosedError
    raise ClosedError.new
  end

  # Serialise the current session fields into an open JSON object.
  # Call this inside a `json.object` block managed by the caller.
  #
  # ```
  # JSON.build do |json|
  #   json.object do
  #     json.field "hero", hero
  #     agent.dump(json)
  #   end
  # end
  # ```
  def dump(json : JSON::Builder) : Nil
    json.field "version", 1
    json.field "session_id", @session_id
    json.field "cache_key", @cache_key
    json.field "history", @history

    # Persist only the names of enabled tools.
    # The actual tool definitions (with callbacks) are application code
    # and must be re-registered before load.
    enabled_names = enabled_tools
    unless enabled_names.empty?
      json.field "enabled_tools", enabled_names
    end
  end

  # Serialise the current session to a JSON string.
  # Includes session_id, cache_key, and the full message history.
  # The output is suitable for later use with `Agent.load`.
  #
  # ```
  # File.write("session.json", agent.dump)
  # ```
  def dump : String
    JSON.build do |json|
      json.object do
        dump(json)
      end
    end
  end

  # Restore an Agent from previously dumped session data.
  #
  # The caller provides a fresh Config (with current API key, endpoint, model).
  # The restored agent carries the same session_id, cache_key, and history as
  # the original, so prompt cache affinity is preserved.
  #
  # Accepts a raw JSON string (shorthand) or a pre-parsed `JSON::Any` hash
  # (useful when the agent data lives inside a larger document).
  #
  # Raises `Agent::SessionLoadError` if the session data is corrupt or
  # malformed. The agent background fiber is **never** leaked — all parsing
  # happens before the private constructor spawns the fiber.
  #
  # ```
  # config = Agent::Config.new(model: "gpt-4o", api_key: ENV["OPENAI_API_KEY"])
  # agent = Agent.load(config, File.read("session.json"))
  # agent.ask("Continue where we left off") # 🚀 cache hit
  #
  # # Or from a nested document:
  # doc = JSON.parse(File.read("save.json")).as_h
  # agent = Agent.load(config, doc["session"])
  # ```
  def self.load(config : Config, data : String | JSON::Any, provider : Provider::Base? = nil) : Agent
    session_id, cache_key, history, enabled_names = extract_session_data(data)

    agent = new(config, session_id, cache_key, provider: provider)

    # Load history into the fiber.
    agent.load_history(history)

    # Restore enabled-tool names. Tools must have been re-registered
    # (with callbacks) before load for this to have any effect.
    enabled_names.each do |name|
      if agent.@registered_tools.has_key?(name)
        entry = agent.@registered_tools[name]
        agent.@registered_tools[name] = entry.merge({enabled: true})
      else
        Log.warn { "Agent.load: tool '#{name}' was enabled in saved session but is not registered — skipping" }
      end
    end

    agent
  end

  # Extract and validate session fields from raw JSON data.
  # All parsing occurs here, before the agent fiber is spawned, so any
  # corruption raises a `SessionLoadError` without leaking resources.
  private def self.extract_session_data(data : String | JSON::Any) : {String, String, Array(Message), Array(String)}
    parsed = begin
      h = data.is_a?(String) ? JSON.parse(data) : data
      h.as_h
    rescue ex
      raise SessionLoadError.new("not a valid JSON object", cause: ex)
    end

    session_id = begin
      parsed["session_id"]?.try(&.as_s)
    rescue ex
      raise SessionLoadError.new("'session_id' field missing or not a string", cause: ex)
    end
    raise SessionLoadError.new("'session_id' field missing or not a string") if session_id.nil?

    cache_key = begin
      parsed["cache_key"]?.try(&.as_s)
    rescue ex
      raise SessionLoadError.new("'cache_key' field missing or not a string", cause: ex)
    end
    raise SessionLoadError.new("'cache_key' field missing or not a string") if cache_key.nil?

    history = begin
      history_raw = parsed["history"]?
      raise SessionLoadError.new("'history' field missing") if history_raw.nil?
      Array(Message).from_json(history_raw.to_json)
    rescue ex
      raise SessionLoadError.new("'history' field is malformed", cause: ex)
    end

    enabled_names = begin
      if (data = parsed["enabled_tools"]?)
        data.as_a.map(&.as_s)
      else
        [] of String
      end
    rescue ex
      raise SessionLoadError.new("'enabled_tools' field is not an array of strings", cause: ex)
    end

    {session_id, cache_key, history, enabled_names}
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

      case request
      in ResetRequest
        # Reset request — clear history and signal completion.
        @history.clear
        request.response.finish(
          Message.new(role: Role::Assistant, content: "History cleared."),
          Usage.new,
        )
      in RegisterToolRequest
        # Register a tool from another fiber.
        @registered_tools[request.name] = {tool: request.tool, callback: request.callback, enabled: request.enabled}
      in EnableToolRequest
        # Enable or disable a tool from another fiber.
        if entry = @registered_tools[request.name]?
          @registered_tools[request.name] = entry.merge({enabled: request.enabled})
          request.response.finish(
            Message.new(role: Role::Assistant, content: "Tool '#{request.name}' #{request.enabled ? "enabled" : "disabled"}."),
            Usage.new,
          )
        else
          request.response.finish_with_error(
            Agent::Error.new("No registered tool named '#{request.name}'")
          )
        end
      in LoadHistoryRequest
        # Restore history from a saved session.
        @history.clear
        @history.concat(request.messages)
        request.response.finish(
          Message.new(role: Role::Assistant, content: "History restored (#{request.messages.size} messages)."),
          Usage.new,
        )
      in AskRequest
        process_request_loop(request)
      end
    end
  rescue Channel::ClosedError
    # agent fiber exits on close — any fiber blocked in a send to the
    # request channel will also see ClosedError and raise to its caller.
  end

  # Process a request with automatic tool resolution.
  # When the model returns tool calls and auto_execute_tools is enabled,
  # registered tools are executed inline and the result is sent back to the
  # model — all within this fiber, without returning to the caller.
  private def process_request_loop(request : AskRequest) : Nil
    response = request.response
    tools = request.tools
    max_iter = @config.max_tool_iterations
    iteration = 0

    # Append new messages to history and build the request body.
    # By appending on the fiber, we avoid concurrent mutations from caller fibers.
    @history.concat(request.new_messages)
    messages = build_messages([] of Message)

    loop do
      iteration += 1

      # Bail out if the model is stuck in a tool-call loop.
      if max_iter && iteration > max_iter
        err_msg = "Agent error: tool call iteration limit (#{max_iter}) exceeded"
        err = ToolLoopError.new(max_iter, err_msg)
        response.finish_with_error(err)
        break
      end

      msg, usage, finish_reason = http_post_stream(messages, tools, response)

      # On error, http_post_stream already called response.finish/finish_with_error.
      # Append the synthetic error message to keep history well-formed.
      if response.error?
        @history << msg
        break
      end

      # Append the assistant message to history. We need this here for the
      # auto-resolve loop (tool results follow this message) and also for the
      # manual-dispatch path (the caller calls #ask(tool_results) next, which
      # requires the assistant(tool_calls) to precede the tool messages).
      @history << msg

      # If no tool calls, or auto_execute is disabled, or no registered tools — done.
      no_tools = !msg.has_tool_calls? || !@config.auto_execute_tools? || @registered_tools.empty?
      if no_tools
        trim_history!
        response.finish(msg, usage, finish_reason: finish_reason)
        break
      end

      # ameba:disable Lint/NotNil
      tool_calls = msg.tool_calls.not_nil!
      results = execute_registered_tools(tool_calls)

      # If some tools had no registered handler, stop and let the caller handle it.
      # NOTE: The assistant(tool_calls) is already in @history. The caller MUST
      # follow up with #ask(tool_results) so the tool messages follow the
      # assistant(tool_calls) — otherwise the next API request will be invalid.
      if results.empty?
        trim_history!
        response.finish(msg, usage, finish_reason: finish_reason)
        break
      end

      # Append tool results to history, then rebuild messages for next iteration.
      @history.concat(results)
      messages = build_messages([] of Message)
    end
  end

  # Trim history to respect max_history config, applied only after a
  # complete user—>assistant turn (not during intermediate tool-call steps).
  #
  # Trims in **turn units** so that tool messages are never orphaned:
  # a "turn" is a user message followed by zero or more assistant + tool
  # messages that belong to it. We drop complete turns from the front
  # until the number of user+assistant messages is at most max*2.
  private def trim_history! : Nil
    if (max = @config.max_history) && max > 0
      # Count only User and Assistant messages (tool messages are auxiliary).
      msg_count = @history.count { |m| m.role == Role::User || m.role == Role::Assistant }
      return unless msg_count > max * 2

      # Walk forward to find how many messages to drop so that at most
      # max*2 user+assistant messages remain. We track the index of the
      # last message that would be dropped.
      keep = max * 2
      dropped = 0
      @history.each_with_index do |m, i|
        break if keep <= 0
        if m.role == Role::User || m.role == Role::Assistant
          keep -= 1
          dropped = i + 1
        end
      end

      # Never split a tool-call group: if the cut point lands in the
      # middle of an assistant(tool_calls)+tool-results sequence, advance
      # to the next safe boundary.
      if dropped < @history.size
        dropped = find_turn_boundary(@history, dropped)
      end

      @history.shift(dropped) if dropped > 0
    end
  end

  # Find the earliest index >= start that is a valid turn boundary.
  # A valid boundary is a User message (starts new turn), or one past
  # an Assistant message without tool_calls (ends the previous turn).
  private def find_turn_boundary(history : Array(Message), start : Int32) : Int32
    idx = start
    while idx < history.size
      m = history[idx]
      return idx if m.role == Role::User
      if m.role == Role::Assistant && !m.has_tool_calls?
        return idx + 1
      end
      idx += 1
    end
    history.size
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
      if entry.nil? || !entry[:enabled]
        return [] of Message
      end

      # Parse the JSON arguments string into a hash for the callback.
      args_hash = begin
        parsed = JSON.parse(tc.arguments)
        parsed.as_h? || {} of String => JSON::Any
      rescue JSON::ParseException
        results << Message.new(
          role: Role::Tool,
          content: "Error parsing arguments for tool '#{tc.name}': invalid JSON",
          tool_call_id: tc.id,
          name: tc.name,
        )
        next
      end

      # Validate arguments against the tool's parameter schema.
      if params_schema = entry[:tool].function.parameters
        errors = validate_tool_args(tc.name, args_hash, params_schema)
        unless errors.empty?
          results << Message.new(
            role: Role::Tool,
            content: "Error validating arguments for tool '#{tc.name}': #{errors.join("; ")}",
            tool_call_id: tc.id,
            name: tc.name,
          )
          next
        end
      end

      result = if cb = entry[:callback]
                begin
                  cb.call(args_hash)
                rescue ex
                  "Error executing tool '#{tc.name}': #{ex.message}"
                end
              else
                "Error executing tool '#{tc.name}': no callback registered"
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

  # Validate tool call arguments against the tool's parameter JSON Schema.
  # Returns an array of error messages (empty = valid).
  private def validate_tool_args(tool_name : String, args : Hash(String, JSON::Any), schema : Hash(String, JSON::Any)) : Array(String)
    errors = [] of String

    props = schema["properties"]?.try(&.as_h?) || {} of String => JSON::Any
    required = schema["required"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String

    # Check required fields are present.
    required.each do |field|
      unless args.has_key?(field)
        errors << "missing required field '#{field}'"
      end
    end

    # Type-check provided fields against the schema.
    args.each do |key, value|
      prop = props[key]?.try(&.as_h?)
      next if prop.nil?

      expected_type = prop["type"]?.try(&.as_s?)
      next if expected_type.nil? || value.raw.nil?

      unless type_matches?(value.raw, expected_type)
        errors << "field '#{key}' expected #{expected_type}, got #{type_name(value.raw)}"
      end
    end

    errors
  end

  # Check if a JSON::Any raw value matches a JSON Schema type name.
  private def type_matches?(raw : JSON::Any::Type?, expected_type : String) : Bool
    case raw
    when String  then expected_type == "string"
    when Int64   then expected_type == "integer" || expected_type == "number"
    when Float64 then expected_type == "number"
    when Bool    then expected_type == "boolean"
    when Array   then expected_type == "array"
    when Hash    then expected_type == "object"
    when Nil     then true # null can be anything
    else              false
    end
  end

  # Human-readable type name for a JSON::Any raw value.
  private def type_name(raw : JSON::Any::Type?) : String
    case raw
    when String  then "string"
    when Int64   then "integer"
    when Float64 then "number"
    when Bool    then "boolean"
    when Array   then "array"
    when Hash    then "object"
    when Nil     then "null"
    else              raw.class.to_s
    end
  end

  # Returns the combined tool list: per-request tools merged with registered tools.
  # Registered tools take precedence over per-request tools with the same name.
  private def combined_tools(tools : Array(Tool)?) : Array(Tool)?
    enabled_reg = @registered_tools.select { |_, v| v[:enabled] }

    if enabled_reg.empty?
      tools
    else
      reg = enabled_reg.values.map(&.[:tool])

      if tools
        # Filter out per-request tools whose name collides with enabled registered tools
        filtered = tools.reject { |t| enabled_reg.has_key?(t.function.name) }
        filtered + reg
      else
        reg
      end
    end
  end

  # Perform the HTTP POST to the provider and parse the streaming response.
  # This is a thin shim that delegates to the provider for wire-format concerns.
  private def http_post_stream(
    messages : Array(Message),
    tools : Array(Tool)?,
    response : Response,
  ) : {Message, Usage, String?}
    all_tools = combined_tools(tools)
    req = @provider.build_request(messages, all_tools)
    client = @http_client

    begin
      client.post(req[:path], headers: req[:headers], body: req[:body]) do |http_resp|
        unless http_resp.status.ok?
          raise ApiError.new(http_resp.status_code, "#{http_resp.status_code} #{http_resp.status_message}")
        end

        msg, usage, finish_reason = @provider.parse_stream(
          http_resp.body_io,
          response,
          -> { response.cancelled? },
        )

        # If the response was cancelled mid-stream, treat it as an error.
        if response.cancelled?
          raise CancelledError.new
        end

        {msg, usage, finish_reason}
      end
    rescue ex : ApiError
      response.finish_with_error(ex)
      {Message.new(role: Role::Assistant, content: "Agent error: #{ex.message || ex.class.name}"), Usage.new, nil}
    rescue ex : CancelledError
      response.finish_with_error(ex)
      {Message.new(role: Role::Assistant, content: "Agent error: #{ex.message || ex.class.name}"), Usage.new, nil}
    rescue ex
      err = ConnectionError.new(ex.message || ex.class.name, cause: ex)
      response.finish_with_error(err)
      {Message.new(role: Role::Assistant, content: "Agent error: #{ex.message || ex.class.name}"), Usage.new, nil}
    end
  end

  private def build_http_client : HTTP::Client
    uri = @provider.base_uri
    client = HTTP::Client.new(uri)

    if (rt = @config.read_timeout) && rt > Time::Span.zero
      client.read_timeout = rt
    end
    if (ct = @config.connect_timeout) && ct > Time::Span.zero
      client.connect_timeout = ct
    end

    client
  end
end
