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
    getter auto_execute_tools : Bool
    getter extra_headers : Hash(String, String)?
    getter stream : Bool

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
      @stream : Bool = true,
    )
      # Validate temperature
      if (t = @temperature) && (t < 0.0 || t > 2.0)
        raise ArgumentError.new("temperature must be between 0.0 and 2.0, got #{t}")
      end

      # Validate max_tokens
      if (mt = @max_tokens) && mt <= 0
        raise ArgumentError.new("max_tokens must be positive, got #{mt}")
      end

      # Validate max_history
      if (mh = @max_history) && mh < 0
        raise ArgumentError.new("max_history must be non-negative, got #{mh}")
      end

      # Accept Int32 seconds for timeouts (convenience)
      @read_timeout = case read_timeout
                      when Int32      then read_timeout.seconds
                      when Time::Span then read_timeout
                      else                 nil
                      end
      @connect_timeout = case connect_timeout
                         when Int32      then connect_timeout.seconds
                         when Time::Span then connect_timeout
                         else                 nil
                         end

      # Validate and parse the endpoint URI
      @parsed_uri = URI.parse(@api_endpoint)
      unless @parsed_uri.scheme && @parsed_uri.host
        raise ArgumentError.new("api_endpoint must be a valid URL, got #{@api_endpoint}")
      end
    end

    # The chat completions path derived from api_endpoint.
    def chat_path : String
      base_path = @parsed_uri.path.empty? || @parsed_uri.path == "/" ? "" : @parsed_uri.path.gsub(/\/+$/, "")
      "#{base_path}/chat/completions"
    end
  end
end
