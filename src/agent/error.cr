class Agent
  # Base error for all Agent-related failures.
  class Error < Exception
  end

  # Raised when a network or connection error occurs during an API request.
  class ConnectionError < Error
    def initialize(message : String, cause : Exception? = nil)
      super(message)
      @cause = cause
    end
  end

  # Raised when the API returns a non-2xx status code.
  class ApiError < Error
    getter status_code : Int32

    def initialize(@status_code : Int32, message : String)
      super(message)
    end
  end

  # Raised when a tool callback raises an exception during auto-execution.
  class ToolError < Error
    getter tool_name : String

    def initialize(@tool_name : String, message : String, cause : Exception? = nil)
      super(message)
      @cause = cause
    end
  end
end
