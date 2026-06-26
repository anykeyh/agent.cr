require "uri"

class Agent
  class Config
    getter api_endpoint : String
    getter api_key : String?
    getter model : String
    getter system_prompt : String?
    getter max_tokens : Int32?
    getter temperature : Float64?
    getter read_timeout : Time::Span?
    getter connect_timeout : Time::Span?
    getter max_history : Int32?
    getter? auto_execute_tools : Bool
    getter extra_headers : Hash(String, String)?
    getter max_tool_iterations : Int32?
    # Explicit prompt cache key. If nil, Agent auto-generates one as
    # "agent-cr:<16-char-hex>" from its own session_id.
    getter prompt_cache_key : String?

    # Cached parsed URI — computed once at construction.
    getter parsed_uri : URI

    def initialize(
      @api_key : String? = nil,
      @api_endpoint : String = "https://api.openai.com/v1",
      @model : String = "gpt-4o",
      @system_prompt : String? = nil,
      @max_tokens : Int32? = nil,
      @temperature : Float64? = nil,
      read_timeout : Time::Span | Int32? = nil,
      connect_timeout : Time::Span | Int32? = nil,
      @max_history : Int32? = nil,
      @auto_execute_tools : Bool = true,
      @extra_headers : Hash(String, String)? = nil,
      @max_tool_iterations : Int32? = 100,
      @prompt_cache_key : String? = nil,
    )
      validate_temperature(@temperature)
      validate_max_tokens(@max_tokens)
      validate_max_history(@max_history)
      validate_max_tool_iterations(@max_tool_iterations)

      # Accept Int32 seconds for timeouts (convenience)
      @read_timeout = parse_timeout(read_timeout)
      @connect_timeout = parse_timeout(connect_timeout)

      # Validate and parse the endpoint URI
      @parsed_uri = URI.parse(@api_endpoint)
      unless @parsed_uri.scheme && @parsed_uri.host
        raise ArgumentError.new("api_endpoint must be a valid URL, got #{@api_endpoint}")
      end
    end

    private def validate_temperature(t : Float64?) : Nil
      if t && (t < 0.0 || t > 2.0)
        raise ArgumentError.new("temperature must be between 0.0 and 2.0, got #{t}")
      end
    end

    private def validate_max_tokens(mt : Int32?) : Nil
      if mt && mt <= 0
        raise ArgumentError.new("max_tokens must be positive, got #{mt}")
      end
    end

    private def validate_max_history(mh : Int32?) : Nil
      if mh && mh < 0
        raise ArgumentError.new("max_history must be non-negative, got #{mh}")
      end
    end

    private def validate_max_tool_iterations(mti : Int32?) : Nil
      if mti && mti < 1
        raise ArgumentError.new("max_tool_iterations must be >= 1, got #{mti}")
      end
    end

    private def parse_timeout(timeout : Time::Span | Int32 | Nil) : Time::Span?
      case timeout
      when Int32      then timeout.seconds
      when Time::Span then timeout
      else                 nil
      end
    end

    # The chat completions path derived from api_endpoint.
    def chat_path : String
      base_path = @parsed_uri.path.empty? || @parsed_uri.path == "/" ? "" : @parsed_uri.path.rstrip('/')
      "#{base_path}/chat/completions"
    end
  end
end
