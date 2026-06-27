require "./spec_helper"

# Test handler classes used by the specs below.

class Agent::Spec::OrderSpy < Agent::Handler
  property tag : String
  property log : Array(String)

  def initialize(@tag, @log)
  end

  def handle(ctx : Agent::TurnContext, next_proc) : {Agent::Message, Agent::Usage, String?}
    @log << "#{@tag}:before"
    result = next_proc.call(ctx)
    @log << "#{@tag}:after"
    result
  end
end

class Agent::Spec::PrefixChunk < Agent::Handler
  property prefix : String

  def initialize(@prefix)
  end

  def handle(ctx : Agent::ChunkContext, next_proc) : Agent::Response::Chunk
    ctx.chunk = Agent::Response::Chunk.new(@prefix + ctx.chunk.text, ctx.chunk.kind)
    next_proc.call(ctx)
  end
end

class Agent::Spec::ShortCircuitTool < Agent::Handler
  property message : Agent::Message

  def initialize(@message)
  end

  def handle(ctx : Agent::ToolCallContext, next_proc) : Agent::Message
    @message
  end
end

class Agent::Spec::RecordingHandler < Agent::Handler
  property log : Array(String)

  def initialize(@log)
  end

  def handle(ctx : Agent::TurnContext, next_proc) : {Agent::Message, Agent::Usage, String?}
    @log << "before"
    result = next_proc.call(ctx)
    @log << "after"
    result
  end
end

# Lock the no-op pass-through contract of Agent::ChainHandler before the
# real chain is built on top of it. Each overload must yield its context
# and return the block's value unchanged.
describe Agent::ChainHandler do
  handler = Agent::ChainHandler.new

  it "passes TurnContext through and returns the block's tuple" do
    msg = Agent::Message.new(role: Agent::Role::Assistant, content: "hi")
    usage = Agent::Usage.new
    ctx = Agent::TurnContext.new([] of Agent::Message, nil)

    result = handler.decorate(ctx) { |_| {msg, usage, "stop"} }
    result.should eq({msg, usage, "stop"})
    # context is the same object the caller passed in
    ctx.should be(ctx)
  end

  it "passes ChunkContext through and returns the block's chunk" do
    chunk = Agent::Response::Chunk.new("hello", Agent::Response::ChunkKind::Content)
    ctx = Agent::ChunkContext.new(chunk)

    result = handler.decorate(ctx, &.chunk)
    result.should be(chunk)
  end

  it "passes ToolCallContext through and returns the block's message" do
    resp = Agent::Response.new
    tc = Agent::ToolCall.new(id: "1", name: "get_time", arguments: "{}")
    ctx = Agent::ToolCallContext.new(tc, resp)
    msg = Agent::Message.new(role: Agent::Role::Tool, content: "noon", tool_call_id: "1")

    result = handler.decorate(ctx) { |_| msg }
    result.should be(msg)
  end

  it "passes ErrorContext through and returns the block's Agent::Error" do
    original = Agent::ConnectionError.new("boom")
    ctx = Agent::ErrorContext.new(original)

    # c.error is typed Exception (any rescued exception may land here), so the
    # block must produce an Agent::Error. The tightened decorate signature
    # rejects a block returning bare Exception at compile time.
    result = handler.decorate(ctx) { |c| c.error.as(Agent::Error) }
    result.should be(original)
    typeof(result).should eq(Agent::Error)
  end

  it "allows a handler to replace the chunk on ChunkContext" do
    # Chunk is a class, so reassigning ctx.chunk is visible to the block.
    original = Agent::Response::Chunk.new("a", Agent::Response::ChunkKind::Content)
    replacement = Agent::Response::Chunk.new("b", Agent::Response::ChunkKind::Content)
    ctx = Agent::ChunkContext.new(original)

    result = handler.decorate(ctx) do |c|
      c.chunk = replacement
      c.chunk
    end
    result.should be(replacement)
  end
end

# Verify that Response clears its chunk_handler on finish/finish_with_error
# so the proc does not retain a closure reference to the Agent after the
# response completes.
describe Agent::Response do
  it "clears chunk_handler on finish" do
    resp = Agent::Response.new
    resp.chunk_handler = ->(c : Agent::Response::Chunk) { c }
    resp.chunk_handler.should_not be_nil

    spawn { resp.finish(Agent::Message.new(role: Agent::Role::Assistant, content: ""), Agent::Usage.new) }
    resp.join
    resp.chunk_handler.should be_nil
  end

  it "clears chunk_handler on finish_with_error" do
    resp = Agent::Response.new
    resp.chunk_handler = ->(c : Agent::Response::Chunk) { c }
    resp.chunk_handler.should_not be_nil

    resp.finish_with_error(Agent::ConnectionError.new("boom"))
    resp.join
    resp.chunk_handler.should be_nil
  end
end

# Chain semantics: handlers run in order, can mutate context, can short-circuit.
describe Agent::Handler do
  it "runs handlers in registration order, wrapping the leaf block" do
    log = [] of String
    chain = Agent::ChainHandler.new
    chain << Agent::Spec::OrderSpy.new("a", log)
    chain << Agent::Spec::OrderSpy.new("b", log)

    ctx = Agent::TurnContext.new([] of Agent::Message, nil)
    chain.decorate(ctx) { |_| {Agent::Message.new(role: Agent::Role::Assistant, content: ""), Agent::Usage.new, "stop"} }

    log.should eq(["a:before", "b:before", "b:after", "a:after"])
  end

  it "lets a handler mutate the context before forwarding" do
    chain = Agent::ChainHandler.new
    chain << Agent::Spec::PrefixChunk.new("pre:")

    ctx = Agent::ChunkContext.new(Agent::Response::Chunk.new("text", Agent::Response::ChunkKind::Content))
    result = chain.decorate(ctx, &.chunk)
    result.text.should eq("pre:text")
  end

  it "lets a handler short-circuit by not calling next" do
    chain = Agent::ChainHandler.new
    chain << Agent::Spec::ShortCircuitTool.new(Agent::Message.new(role: Agent::Role::Tool, content: "blocked"))

    resp = Agent::Response.new
    tc = Agent::ToolCall.new(id: "1", name: "x", arguments: "{}")
    ctx = Agent::ToolCallContext.new(tc, resp)
    result = chain.decorate(ctx) { |_| Agent::Message.new(role: Agent::Role::Tool, content: "should-not-run") }
    result.content.should eq("blocked")
  end

  it "empty chain just calls the leaf block" do
    chain = Agent::ChainHandler.new
    ctx = Agent::ChunkContext.new(Agent::Response::Chunk.new("x", Agent::Response::ChunkKind::Content))
    result = chain.decorate(ctx, &.chunk)
    result.text.should eq("x")
  end
end

# Agent#use appends handlers to the agent's chain.
describe Agent do
  it "#use appends a handler to the chain" do
    agent = Agent.new(Agent::Config.new(api_key: "k", api_endpoint: "http://localhost:1", model: "m"))
    log = [] of String

    agent.use(Agent::Spec::RecordingHandler.new(log))
    agent.use(Agent::Spec::RecordingHandler.new(log))

    # The chain now has two handlers; both should wrap a decorate call.
    ctx = Agent::TurnContext.new([] of Agent::Message, nil)
    agent.@handlers.decorate(ctx) { |_| {Agent::Message.new(role: Agent::Role::Assistant, content: ""), Agent::Usage.new, "stop"} }
    log.should eq(["before", "before", "after", "after"])
  end
end
