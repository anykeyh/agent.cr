require "sync"

class Agent
  # A handle on the pending response from #ask.
  # Wraps the ongoing fiber-based HTTP streaming and provides
  # streaming chunks, final message, metadata, and wait/join operations.
  #
  # Synchronization:
  #   - `chunk_channel` (size 256): legitimate stream queue with backpressure.
  #   - `message_channel` (size 1) and `usage_channel` (size 1): legitimate
  #     one-shot futures for the final message and usage metadata.
  #   - Shared flags (@done, @cancelled, @streaming, @finish_reason, @error)
  #     are protected by a Mutex. The old `cancel_channel` (unconsumed) has
  #     been removed in favor of a mutex-protected bool.
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

    # --- mutex-protected shared state ---

    @mutex : Sync::Mutex
    @done = false
    @cancelled = false
    @streaming = false
    @finish_reason : String?
    @error : Agent::Error?

    # Cached values so the second call to #message / #metadata
    # does not block on the channel again.
    @message : Message?
    @metadata : Usage?

    def initialize
      @chunk_channel = Channel(Chunk).new(CHUNK_BUFFER)
      @message_channel = Channel(Message).new(1)
      @usage_channel = Channel(Usage).new(1)
      @mutex = Sync::Mutex.new
    end

    # Shorthand for @mutex.synchronize — used by all flag accessors.
    private def synchronize(&)
      @mutex.synchronize { yield }
    end

    # Request cancellation of this in-flight response.
    # The HTTP fiber will abort after the current SSE line is processed.
    # Safe to call from any fiber. Idempotent.
    # After cancellation, #message returns a "Agent error: cancelled" message
    # and #error returns a CancelledError.
    def cancel : Nil
      synchronize { @cancelled = true }
    end

    # Returns true if cancel was requested.
    def cancelled? : Bool
      synchronize { @cancelled }
    end

    # Returns true when the response has finished assembling.
    def finished? : Bool
      synchronize { @done }
    end

    # The reason the stream finished ("stop", "length", "tool_calls", etc.)
    # or nil if not known / the request errored.
    def finish_reason : String?
      synchronize { @finish_reason }
    end

    # Returns the error if this response represents a failed request, or nil.
    def error : Agent::Error?
      synchronize { @error }
    end

    # Returns true if this response represents a failed request.
    def error? : Bool
      synchronize { !@error.nil? }
    end

    # Return the fully assembled message (blocks until ready).
    def message : Message
      @message ||= begin
        msg = @message_channel.receive
        synchronize { @message = msg }
        msg
      end
    rescue Channel::ClosedError
      @message || raise("BUG: message channel closed without delivering a message")
    end

    # Return the metadata / usage (blocks until ready).
    def metadata : Usage
      @metadata ||= begin
        meta = @usage_channel.receive
        synchronize { @metadata = meta }
        meta
      end
    rescue Channel::ClosedError
      @metadata || Usage.new
    end

    # Wait for the response to complete (both message and usage).
    def join : Nil
      message
      metadata
    end

    # Yields each chunk as it arrives from the API.
    # Use `chunk.text` for the string and `chunk.kind` for its origin.
    def stream(& : Chunk -> _) : Nil
      synchronize { @streaming = true }
      loop do
        chunk = @chunk_channel.receive
        yield chunk
      end
    rescue Channel::ClosedError
      # streaming finished
    end

    # Internal: push a chunk (safe to call from any fiber).
    # Uses a buffered channel with capacity 256.
    #
    # When nobody is consuming via #stream, chunks are discarded entirely
    # — the final message is assembled from SSE deltas regardless, so
    # dropping character-level chunks does not affect correctness.
    # This prevents deadlocks when the model emits long tool-call
    # argument strings and the caller uses #message directly.
    #
    # When #stream is active, blocks until the consumer reads.
    def push_chunk(chunk : Chunk) : Nil
      return unless synchronize { @streaming }

      @chunk_channel.send(chunk)
    rescue Channel::ClosedError
      # already finished
    end

    # Internal: signal that the response is complete.
    # Safe to call multiple times — subsequent calls are no-ops.
    def finish(message : Message, usage : Usage, finish_reason : String? = nil) : Nil
      synchronize do
        return if @done
        @done = true
        @finish_reason = finish_reason
        @message = message
        @metadata = usage
      end
      @message_channel.send(message)
      @usage_channel.send(usage)
    ensure
      @chunk_channel.close
    end

    # Internal: signal that the response failed with an error.
    # Stores the error and sends an error message through the normal channels
    # so consumers can still call #message.
    def finish_with_error(err : Agent::Error) : Nil
      error_msg = Message.new(role: Role::Assistant, content: "Agent error: #{err.message}")

      synchronize do
        return if @done
        @done = true
        @error = err
        @message = error_msg
        @metadata = Usage.new
      end
      @message_channel.send(error_msg)
      @usage_channel.send(Usage.new)
    ensure
      @chunk_channel.close
    end
  end
end
