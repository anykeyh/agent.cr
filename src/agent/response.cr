class Agent
  # A handle on the pending response from #ask.
  # Wraps the ongoing fiber-based HTTP streaming and provides
  # streaming chunks, final message, metadata, and wait/join operations.
  class Response
    CHUNK_BUFFER = 256

    # Tags a streamed chunk with its origin.
    enum ChunkKind
      Content
      Reasoning
      ToolCallArgs
      ToolCallName
    end

    # A streamed text chunk tagged with its origin.
    struct Chunk
      getter text : String
      getter kind : ChunkKind

      def initialize(@text : String, @kind : ChunkKind = ChunkKind::Content)
      end

      def content? : Bool
        @kind == ChunkKind::Content
      end

      def reasoning? : Bool
        @kind == ChunkKind::Reasoning
      end

      def tool_call_name? : Bool
        @kind == ChunkKind::ToolCallName
      end

      def tool_call_args? : Bool
        @kind == ChunkKind::ToolCallArgs
      end
    end

    # --- channels used internally by the agent ---

    # The fiber pushes streamed Chunks here.
    private getter chunk_channel : Channel(Chunk)
    # Signals the final Message once fully built.
    private getter message_channel : Channel(Message)
    # Signals the final Usage metadata.
    private getter usage_channel : Channel(Usage)
    # Signals cancellation to the processing fiber.
    private getter cancel_channel : Channel(Nil)

    @message : Message?
    @metadata : Usage?
    @done = false
    @cancelled = false
    @finish_reason : String?
    @error : Agent::Error?

    def initialize
      @chunk_channel = Channel(Chunk).new(CHUNK_BUFFER)
      @message_channel = Channel(Message).new(1)
      @usage_channel = Channel(Usage).new(1)
      @cancel_channel = Channel(Nil).new(1)
    end

    # Request cancellation of this in-flight response.
    # The HTTP fiber will abort after the current SSE line is processed.
    # Safe to call from any fiber. Idempotent.
    def cancel : Nil
      return if @cancelled

      @cancelled = true
      @cancel_channel.send(nil)
    rescue Channel::ClosedError
      # already finished
    end

    # Returns true if cancel was requested.
    def cancelled? : Bool
      @cancelled
    end

    # Returns true when the response has finished assembling.
    def finished? : Bool
      @done
    end

    # The reason the stream finished ("stop", "length", "tool_calls", etc.)
    # or nil if not known / the request errored.
    def finish_reason : String?
      @finish_reason
    end

    # Returns the error if this response represents a failed request, or nil.
    def error : Agent::Error?
      @error
    end

    # Returns true if this response represents a failed request.
    def error? : Bool
      !@error.nil?
    end

    # Return the fully assembled message (blocks until ready).
    def message : Message
      @message ||= @message_channel.receive
    end

    # Return the metadata / usage (blocks until ready).
    def metadata : Usage
      @metadata ||= @usage_channel.receive
    end

    # Wait for the response to complete (both message and usage).
    def join : Nil
      message
      metadata
    end

    # Yields each chunk as it arrives from the API.
    # Use `chunk.text` for the string and `chunk.kind` for its origin.
    def stream(& : Chunk -> _) : Nil
      loop do
        chunk = @chunk_channel.receive
        yield chunk
      end
    rescue Channel::ClosedError
      # streaming finished
    end

    # Internal: push a chunk (safe to call from any fiber).
    # Uses a buffered channel to avoid blocking when nobody is consuming
    # via #stream (e.g. caller uses #message directly).
    def push_chunk(chunk : Chunk) : Nil
      @chunk_channel.send(chunk)
    rescue Channel::ClosedError
      # already finished
    end

    # Internal: signal that the response is complete.
    # Safe to call multiple times — subsequent calls are no-ops.
    def finish(message : Message, usage : Usage, finish_reason : String? = nil) : Nil
      return if @done

      @done = true
      @finish_reason = finish_reason
      @message_channel.send(message)
      @usage_channel.send(usage)
    ensure
      @chunk_channel.close
    end

    # Internal: signal that the response failed with an error.
    # Stores the error and sends an error message through the normal channels
    # so consumers can still call #message.
    def finish_with_error(err : Agent::Error) : Nil
      return if @done

      @done = true
      @error = err
      error_msg = Message.new(role: Role::Assistant, content: "Agent error: #{err.message}")
      @message_channel.send(error_msg)
      @usage_channel.send(Usage.new)
    ensure
      @chunk_channel.close
    end
  end
end
