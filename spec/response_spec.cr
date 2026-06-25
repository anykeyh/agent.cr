require "./spec_helper"

# We test the Agent::Response in isolation (channels, stream, join, finished?)
# without any HTTP dependency.

describe Agent::Response do
  it "starts not finished" do
    resp = Agent::Response.new
    resp.finished?.should be_false
  end

  it "streams chunks via the block" do
    resp = Agent::Response.new
    chunks = [] of String

    spawn do
      resp.push_chunk(Agent::Response::Chunk.new("Hello ", Agent::Response::ChunkKind::Content))
      resp.push_chunk(Agent::Response::Chunk.new("world", Agent::Response::ChunkKind::Content))
      resp.finish(Agent::Message.new(role: Agent::Role::Assistant, content: "Hello world"), Agent::Usage.new)
    end

    resp.stream { |chunk| chunks << chunk.text }
    chunks.should eq(["Hello ", "world"])
  end

  it "returns the final message" do
    resp = Agent::Response.new
    msg = Agent::Message.new(role: Agent::Role::Assistant, content: "Paris")

    spawn do
      resp.finish(msg, Agent::Usage.new)
    end

    resp.message.content.should eq("Paris")
  end

  it "returns usage metadata" do
    resp = Agent::Response.new
    usage = Agent::Usage.new(prompt_tokens: 10, completion_tokens: 20, total_tokens: 30)

    spawn do
      resp.finish(Agent::Message.new(role: Agent::Role::Assistant, content: ""), usage)
    end

    meta = resp.metadata
    meta.total_tokens.should eq(30)
  end

  it "blocking join waits for completion" do
    resp = Agent::Response.new
    done = Channel(Nil).new

    spawn do
      resp.join
      done.send(nil)
    end

    sleep(1.millisecond) # let the spawned fiber block on join
    resp.finish(Agent::Message.new(role: Agent::Role::Assistant, content: "Done"), Agent::Usage.new)

    select
    when done.receive
      # ok
    when timeout(1.second)
      fail("join did not complete in time")
    end
  end

  it "is finished after finish is called" do
    resp = Agent::Response.new
    spawn { resp.finish(Agent::Message.new(role: Agent::Role::Assistant, content: ""), Agent::Usage.new) }
    resp.join
    resp.finished?.should be_true
  end

  it "caches message on second call" do
    resp = Agent::Response.new
    msg = Agent::Message.new(role: Agent::Role::Assistant, content: "Cached")
    spawn { resp.finish(msg, Agent::Usage.new) }
    resp.message.should be(msg)
    resp.message.should be(msg) # second call returns cached, not channel receive
  end
end
