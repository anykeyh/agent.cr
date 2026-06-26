class Agent
  # Base error for all Agent-related failures.
  class Error < Exception
  end

  # Raised when a network or connection error occurs during an API request.
  class ConnectionError < Error
    def initialize(message : String, cause : Exception? = nil)
      super(message, cause: cause)
    end
  end

  # Raised when the API returns a non-2xx status code.
  class ApiError < Error
    getter status_code : Int32

    def initialize(@status_code : Int32, message : String)
      super(message)
    end
  end

  # Raised when the automatic tool-resolution loop exceeds the iteration limit.
  class ToolLoopError < Error
    getter max_iterations : Int32

    def initialize(@max_iterations : Int32, message : String)
      super(message)
    end
  end

  # Raised when the caller cancels an in-flight response.
  class CancelledError < Error
    def initialize
      super("Response was cancelled by caller")
    end
  end

  # Raised when loading a session from serialised data fails due to
  # missing fields, type mismatches, or invalid message format.
  class SessionLoadError < Error
    getter reason : String

    def initialize(@reason : String, cause : Exception? = nil)
      super("Failed to load session: #{reason}", cause: cause)
    end
  end

  # Raised when a tool call provides invalid arguments
  # that don't match the tool's parameter schema.
  class ToolArgumentError < Error
    getter tool_name : String
    getter errors : Array(String)

    def initialize(@tool_name : String, @errors : Array(String))
      super("Tool '#{@tool_name}' received invalid arguments: #{@errors.join("; ")}")
    end
  end
end
