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

  # Raised when an SSE stream stalls — no bytes arrive on `body_io` within
  # the configured first-byte or idle read timeout. The HTTP fiber catches
  # `IO::TimeoutError` from the underlying socket and re-raises it as this so
  # callers can pattern-match on `Agent::Error` types.
  #
  # `phase` is `:first_byte` (no data between POST-send and the first SSE
  # line) or `:idle` (gap between two consecutive lines mid-stream).
  class IdleTimeoutError < Error
    getter phase : Symbol
    getter timeout : Time::Span?

    def initialize(@phase : Symbol, @timeout : Time::Span? = nil, cause : Exception? = nil)
      budget = timeout.try(&.total_seconds.try(&.round(2)))
      msg = case @phase
            when :first_byte then "Agent error: provider did not emit the first byte within #{budget}s of sending the request"
            else                  "Agent error: provider stream stalled — no bytes received within the #{budget}s idle timeout"
            end
      super(msg, cause: cause)
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
end
