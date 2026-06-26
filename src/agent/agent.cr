require "json"
require "http/client"
require "sync"

class Agent
  # Raised when trying to use an Agent that has been closed.
  class ClosedError < Error
    def initialize
      super("Agent has been closed")
    end
  end

  # Internal request types sent to the processing fiber.
  # After the mutex migration, only AskRequest remains on the channel.
  # All control operations (register_tool, enable_tool, reset, etc.) now use
  # direct mutex-protected access instead of channel round-trips.
  private record AskRequest, new_messages : Array(Message), tools : Array(Tool)?, response : Response

  private alias Request = AskRequest

  getter config : Config
  getter session_id : String
  getter cache_key : String

  # Return a snapshot of the conversation history.
  # Thread-safe; acquires @history_mutex internally.
  def history : Array(Message)
    @history_mutex.synchronize { @history.dup }
  end

  @request_channel : Channel(Request)
  @fiber : Fiber
  @closed = false
  @registered_tools : Hash(String, NamedTuple(tool: Tool, callback: (Hash(String, JSON::Any) -> String)?, enabled: Bool))
  @history : Array(Message)

  # Mutexes for shared state.
  # @state_mutex protects @closed (used by close and the @closed checks).
  # @history_mutex protects @history (used by process_request_loop, reset, load_history, snapshot).
  # @tools_mutex protects @registered_tools (used by register/enable/disable tool, snapshot).
  @state_mutex : Sync::Mutex
  @history_mutex : Sync::Mutex
  @tools_mutex : Sync::Mutex

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
    @state_mutex = Sync::Mutex.new
    @history_mutex = Sync::Mutex.new
    @tools_mutex = Sync::Mutex.new
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
    @state_mutex = Sync::Mutex.new
    @history_mutex = Sync::Mutex.new
    @tools_mutex = Sync::Mutex.new
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
  # No longer uses a channel round-trip — acquires @tools_mutex directly.
  # Safe to call from any fiber, including the agent fiber itself.
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
    @state_mutex.synchronize { raise ClosedError.new if @closed }
    raise ArgumentError.new("Tool name must not be empty") if name.empty?

    tool = Tool.new(Tool::FunctionDef.new(name: name, description: description, parameters: parameters))
    entry = {tool: tool, callback: block, enabled: enabled}

    @tools_mutex.synchronize { @registered_tools[name] = entry }
  end

  # Enable a previously registered tool, making it available to the model.
  # Returns `false` if no tool with that name is registered.
  # Safe to call from any fiber.
  def enable_tool(name : String) : Bool
    @state_mutex.synchronize { raise ClosedError.new if @closed }

    @tools_mutex.synchronize do
      return false unless @registered_tools.has_key?(name)
      @registered_tools[name] = @registered_tools[name].merge({enabled: true})
      true
    end
  end

  # Disable a registered tool, hiding it from the model without unregistering it.
  # Returns `false` if no tool with that name is registered.
  # Safe to call from any fiber.
  def disable_tool(name : String) : Bool
    @state_mutex.synchronize { raise ClosedError.new if @closed }

    @tools_mutex.synchronize do
      return false unless @registered_tools.has_key?(name)
      @registered_tools[name] = @registered_tools[name].merge({enabled: false})
      true
    end
  end

  # Returns the names of all currently enabled tools.
  # Thread-safe; acquires @tools_mutex internally.
  def enabled_tools : Array(String)
    @tools_mutex.synchronize { @registered_tools.select { |_, v| v[:enabled] }.keys }
  end

  # Close the agent, shutting down the background fiber.
  # Any pending or future #ask calls will get a closed-error response.
  # Safe to call multiple times.
  #
  # NOTE: Do not call #close from inside a tool callback — if you need
  # to stop the agent mid-callback, prefer response.cancel on the
  # current Response. Calling #close from a tool callback will close
  # the HTTP client underneath the in-flight request.
  def close : Nil
    @state_mutex.synchronize { return if @closed; @closed = true }
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
    @state_mutex.synchronize { raise ClosedError.new if @closed }

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
    @state_mutex.synchronize { raise ClosedError.new if @closed }

    response = Response.new
    @request_channel.send(AskRequest.new(tool_results, tools, response))
    response
  rescue Channel::ClosedError
    raise ClosedError.new
  end

  # Reset the conversation history back to the system prompt only.
  #
  # NOTE: Calling #reset while an #ask is in-flight is undefined behavior.
  # Wait for any in-flight Response to complete (via #join) first.
  #
  # Raises Agent::ClosedError if the agent has been closed.
  def reset : Nil
    @state_mutex.synchronize { raise ClosedError.new if @closed }
    @history_mutex.synchronize { @history.clear }
  end

  # Restore the full conversation history.
  # This replaces the current history with the given messages (e.g. from a
  # previous `#dump`). The system prompt is NOT included — `build_messages`
  # prepends it from Config as usual.
  #
  # NOTE: Calling #load_history while an #ask is in-flight is undefined behavior.
  # Wait for any in-flight Response to complete (via #join) first.
  #
  # Raises Agent::ClosedError if the agent has been closed.
  def load_history(messages : Array(Message)) : Nil
    @state_mutex.synchronize { raise ClosedError.new if @closed }
    @history_mutex.synchronize do
      @history.clear
      @history.concat(messages)
    end
  end

  # Serialise the current session fields into an open JSON object.
  # Call this inside a `json.object` block managed by the caller.
  #
  # Thread-safe; acquires @history_mutex and @tools_mutex internally.
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
    result = snapshot_session

    json.field "version", 1
    json.field "session_id", result.session_id
    json.field "cache_key", result.cache_key
    json.field "history", result.history

    # Persist only the names of enabled tools.
    # The actual tool definitions (with callbacks) are application code
    # and must be re-registered before load.
    tools = result.enabled_tools
    unless tools.empty?
      json.field "enabled_tools", tools
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

  # Internal: fetch session snapshot with mutex protection.
  # Replaces the earlier channel-based DumpRequest round-trip.
  private def snapshot_session : DumpResult
    history_dup = @history_mutex.synchronize { @history.dup }
    enabled_names = @tools_mutex.synchronize { @registered_tools.select { |_, v| v[:enabled] }.keys }
    DumpResult.new(
      session_id: @session_id,
      cache_key: @cache_key,
      history: history_dup,
      enabled_tools: enabled_names,
    )
  end

  # Result carrier for session snapshot.
  private record DumpResult,
    session_id : String,
    cache_key : String,
    history : Array(Message),
    enabled_tools : Array(String)

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
    agent.@tools_mutex.synchronize do
      enabled_names.each do |name|
        if agent.@registered_tools.has_key?(name)
          entry = agent.@registered_tools[name]
          agent.@registered_tools[name] = entry.merge({enabled: true})
        else
          Log.warn { "Agent.load: tool '#{name}' was enabled in saved session but is not registered — skipping" }
        end
      end
    end

    agent
  end

  # Extract and validate session fields from raw JSON data.
  # All parsing occurs here, before the agent fiber is spawned, so any
  # corruption raises a `SessionLoadError` without leaking resources.
  private def self.extract_session_data(data : String | JSON::Any) : {String, String, Array(Message), Array(String)}
    parsed = parse_session_root(data)
    {
      parse_session_id(parsed),
      parse_cache_key(parsed),
      parse_history(parsed),
      parse_enabled_tools(parsed),
    }
  end

  private def self.parse_session_root(data : String | JSON::Any) : Hash(String, JSON::Any)
    h = data.is_a?(String) ? JSON.parse(data) : data
    h.as_h
  rescue ex
    raise SessionLoadError.new("not a valid JSON object", cause: ex)
  end

  private def self.parse_session_id(parsed : Hash(String, JSON::Any)) : String
    id = begin
      parsed["session_id"]?.try(&.as_s)
    rescue ex
      raise SessionLoadError.new("'session_id' field missing or not a string", cause: ex)
    end
    raise SessionLoadError.new("'session_id' field missing or not a string") if id.nil?
    id
  end

  private def self.parse_cache_key(parsed : Hash(String, JSON::Any)) : String
    key = begin
      parsed["cache_key"]?.try(&.as_s)
    rescue ex
      raise SessionLoadError.new("'cache_key' field missing or not a string", cause: ex)
    end
    raise SessionLoadError.new("'cache_key' field missing or not a string") if key.nil?
    key
  end

  private def self.parse_history(parsed : Hash(String, JSON::Any)) : Array(Message)
    history_raw = parsed["history"]?
    raise SessionLoadError.new("'history' field missing") if history_raw.nil?
    Array(Message).from_json(history_raw.to_json)
  rescue ex
    raise SessionLoadError.new("'history' field is malformed", cause: ex)
  end

  private def self.parse_enabled_tools(parsed : Hash(String, JSON::Any)) : Array(String)
    if data = parsed["enabled_tools"]?
      data.as_a.map(&.as_s)
    else
      [] of String
    end
  rescue ex
    raise SessionLoadError.new("'enabled_tools' field is not an array of strings", cause: ex)
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  private def build_messages(history : Array(Message), msgs_to_append : Array(Message)) : Array(Message)
    msgs = [] of Message

    if (sys = @config.system_prompt) && !sys.empty?
      msgs << Message.new(role: Role::System, content: sys)
    end

    msgs.concat(history)
    msgs.concat(msgs_to_append)
    msgs
  end

  private def run_loop : Nil
    loop do
      request = @request_channel.receive
      case request
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
  #
  # Access to @history and @registered_tools is synchronized via
  # @history_mutex and @tools_mutex. The HTTP call happens outside the locks.
  private def process_request_loop(request : AskRequest) : Nil
    response = request.response
    tools = request.tools
    max_iter = @config.max_tool_iterations
    iteration = 0

    # Append new messages to history under the lock, then snapshot for the HTTP call.
    history_snapshot = @history_mutex.synchronize do
      @history.concat(request.new_messages)
      @history.dup
    end
    messages = build_messages(history_snapshot, [] of Message)

    loop do
      iteration += 1

      # If the agent was closed during tool execution, bail out.
      if @state_mutex.synchronize { @closed }
        err = Agent::Error.new("Agent was closed")
        response.finish_with_error(err)
        break
      end

      # If the caller cancelled during tool execution, bail out.
      if response.cancelled?
        err = CancelledError.new
        response.finish_with_error(err)
        break
      end

      # Bail out if the model is stuck in a tool-call loop.
      if max_iter && iteration > max_iter
        err_msg = "Agent error: tool call iteration limit (#{max_iter}) exceeded"
        err = ToolLoopError.new(max_iter, err_msg)
        response.finish_with_error(err)
        break
      end

      msg, usage, finish_reason = http_post_stream(messages, tools, response)

      # On error, http_post_stream already called response.finish/finish_with_error.
      # Roll back the user messages that were appended at the start of this
      # request so history is not corrupted for subsequent #ask calls.
      if response.error?
        @history_mutex.synchronize do
          request.new_messages.each { @history.pop }
        end
        break
      end

      # Append the assistant message to history under the lock.
      @history_mutex.synchronize { @history << msg }

      # Determine whether to auto-resolve tools.
      # Read @registered_tools under the lock.
      has_registered_tools = @tools_mutex.synchronize { !@registered_tools.empty? }

      # If no tool calls, or auto_execute is disabled, or no registered tools — done.
      no_tools = !msg.has_tool_calls? || !@config.auto_execute_tools? || !has_registered_tools
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

      # Append tool results to history under the lock, then rebuild messages for next iteration.
      @history_mutex.synchronize { @history.concat(results) }
      history_snapshot = @history_mutex.synchronize { @history.dup }
      messages = build_messages(history_snapshot, [] of Message)
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
      drop_count = 0
      keep_count = msg_count - max * 2
      kept = 0

      @history.each_with_index do |m, idx|
        if kept >= keep_count
          # We've found the first complete turn to keep.
          # Drop everything up to (but not including) here.
          drop_count = idx
          break
        end

        if m.role == Role::User || m.role == Role::Assistant
          kept += 1
        end
      end

      # If we found a boundary, drop from the front.
      if drop_count > 0
        @history = @history[drop_count..]
      end
    end
  end

  # Walk backwards from the given index (exclusive) to find the index of the
  # preceding user message, ensuring we don't split a turn.
  private def find_turn_boundary(start_idx : Int32) : Int32
    idx = start_idx - 2
    while idx >= 0
      return idx if @history[idx].role == Role::User
      idx -= 1
    end
    0
  end

  # Execute all tool calls that have registered callbacks.
  # Returns the array of tool-result messages. Returns an **empty** array if any
  # tool call has no registered handler.
  # If a callback raises, the error is caught and returned as a tool-result
  # message with an error description, so the agent fiber never dies.
  private def execute_registered_tools(tool_calls : Array(ToolCall)) : Array(Message)
    results = [] of Message

    tool_calls.each do |tc|
      entry = @tools_mutex.synchronize { @registered_tools[tc.name]? }
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
        errors << "Missing required field '#{field}'"
      end
    end

    # Check that all provided arguments have known types.
    args.each do |key, value|
      if prop = props[key]?
        if type_name = type_name(value)
          expected = prop["type"]?.try(&.as_s)
          if expected && !type_matches?(type_name, expected)
            errors << "Field '#{key}' expected type '#{expected}', got '#{type_name}'"
          end
        end
      end
    end

    errors
  end

  private def type_matches?(actual_type : String, expected_type : String) : Bool
    case expected_type
    when "integer"
      actual_type == "integer" || actual_type == "number"
    when "number"
      actual_type == "integer" || actual_type == "number"
    when "array"
      actual_type == "array"
    when "object"
      actual_type == "object"
    when "string"
      actual_type == "string"
    when "boolean"
      actual_type == "boolean"
    else
      true
    end
  end

  # Return the JSON type name of a JSON::Any value.
  private def type_name(value : JSON::Any) : String?
    case value.raw
    when String
      "string"
    when Int64, Int32, Int16, Int8
      "number"
    when Float64, Float32
      "number"
    when Bool
      "boolean"
    when Array
      "array"
    when Hash
      "object"
    when Nil
      nil
    else
      nil
    end
  end

  # Returns the combined tool list: per-request tools merged with registered tools.
  # Registered tools take precedence over per-request tools with the same name.
  private def combined_tools(tools : Array(Tool)?) : Array(Tool)?
    enabled_reg = @tools_mutex.synchronize { @registered_tools.select { |_, v| v[:enabled] } }

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
