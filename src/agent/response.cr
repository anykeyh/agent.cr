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
    end

    # --- channels used internally by the agent ---

    # The fiber pushes streamed Chunks here.
    getter chunk_channel : Channel(Chunk)
    # Signals the final Message once fully built.
    getter message_channel : Channel(Message)
    # Signals the final Usage metadata.
    getter usage_channel : Channel(Usage)

    @message : Message?
    @metadata : Usage?
    @done = false

    def initialize
      @chunk_channel = Channel(Chunk).new(CHUNK_BUFFER)
      @message_channel = Channel(Message).new(1)
      @usage_channel = Channel(Usage).new(1)
    end

    # Returns true when the response has finished assembling.
    def finished? : Bool
      @done
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
    def finish(message : Message, usage : Usage) : Nil
      return if @done

      @done = true
      @message_channel.send(message)
      @usage_channel.send(usage)
    ensure
      @chunk_channel.close
    end
  end
end
